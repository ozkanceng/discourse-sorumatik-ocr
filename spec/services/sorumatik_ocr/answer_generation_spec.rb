# frozen_string_literal: true
require "rails_helper"

describe SorumatikOcr::AnswerGeneration do
  fab!(:user)
  fab!(:bot) { Fabricate(:user, username: "sorumatik_ai") }
  fab!(:source) { Fabricate(:post, user: user) }

  before do
    SiteSetting.gemini_ocr_enabled = true
    SiteSetting.gemini_ai_solve_enabled = true
    SiteSetting.gemini_ai_solve_bot_username = bot.username
    SiteSetting.gemini_ocr_api_key = "test-key"
    Jobs.stubs(:enqueue)
    Jobs.stubs(:enqueue_in)
    MessageBus.stubs(:publish)
  end

  def generation
    described_class.start!(source)
  end

  it "shares the durable identity across repeated mobile and automation starts" do
    first = generation
    expect(described_class.start!(source).id).to eq(first.id)
    expect(SorumatikOcr::AiGeneration.where(source_post_id: source.id).count).to eq(1)
    expect(ActiveRecord::Base.connection.indexes(:sorumatik_ai_generations)).to include(
      an_object_having_attributes(columns: ["source_post_id"], unique: true),
    )
  end

  it "saves the exact streamed raw and publishes completed only after persistence" do
    record = generation
    stream = mock("provider")
    SorumatikOcr::GeminiAnswerStream.expects(:new).once.returns(stream)
    stream.expects(:each_delta).multiple_yields(["Türkçe $x=2$"], ["\n\n**Cevap:** 2"])
    MessageBus.expects(:publish).at_least_once.with do |_channel, snapshot, **_options|
      snapshot[:state] != "completed" || Post.find(snapshot[:post_id]).raw == snapshot[:raw]
    end
    described_class.new(record).run!
    expect(record.reload.state).to eq("completed")
    expect(record.post.raw).to eq("Türkçe $x=2$\n\n**Cevap:** 2")
    expect(record.snapshot[:content_sha256]).to eq(Digest::SHA256.hexdigest(record.post.raw))
    described_class.new(record).run! # duplicate queued job must not call Gemini
  end

  it "retries persistence with the existing raw without invoking Gemini" do
    record = generation
    record.update!(state: "persisting", raw: "Hazır cevap")
    SorumatikOcr::GeminiAnswerStream.expects(:new).never
    PostCreator.any_instance.expects(:create!).once.raises(StandardError, "database unavailable")
    described_class.new(record).persist!
    expect(record.reload.state).to eq("persisting")
    expect(record.raw).to eq("Hazır cevap")
    expect(record.post_id).to be_nil
    PostCreator.any_instance.unstub(:create!)
    described_class.new(record).run!
    expect(record.reload.state).to eq("completed")
    expect(record.post.raw).to eq("Hazır cevap")
  end

  it "never acknowledges a different existing answer as a successful import" do
    existing = Fabricate(:post, topic: source.topic, user: bot, reply_to_post_number: source.post_number, raw: "Eski cevap")
    expect { described_class.import!(source, "Farklı canlı cevap") }.to raise_error(SorumatikOcr::GeminiAnswerStream::Failure, "answer_conflict")
    expect(existing.reload.raw).to eq("Eski cevap")
  end

  it "keeps partial text on failure and does not restart failed generation" do
    record = generation
    stream = Object.new
    def stream.each_delta
      yield "Kısmi cevap"
      yield " korunur"
      raise SorumatikOcr::GeminiAnswerStream::Failure.new("incomplete_stream")
    end
    SorumatikOcr::GeminiAnswerStream.expects(:new).once.returns(stream)
    described_class.new(record).run!
    expect(record.reload.state).to eq("failed")
    expect(record.raw).to eq("Kısmi cevap korunur")
    expect(record.post_id).to be_nil
    expect(described_class.start!(source).generation_id).to eq(record.generation_id)
    described_class.new(record).run!
  end

  it "uses the followup message and previous conversation, excluding future messages and whispers" do
    Fabricate(:post, topic: source.topic, user: bot, raw: "Önceki cevap")
    whisper = Fabricate(:post, topic: source.topic, post_type: Post.types[:whisper], raw: "Gizli moderatör notu")
    followup = Fabricate(:post, topic: source.topic, user: user, raw: "Bu adımı açıkla @sorumatik_ai")
    future = Fabricate(:post, topic: source.topic, raw: "Gelecek mesaj")
    record = described_class.start!(followup)
    contents = described_class.new(record).send(:build_contents, followup)
    expect(contents.last[:parts].last[:text]).to eq(followup.raw)
    expect(contents.first[:parts].last[:text]).to eq(source.raw)
    expect(contents.any? { |message| message[:role] == "model" }).to eq(true)
    expect(contents.to_s).not_to include(future.raw)
    expect(contents.to_s).not_to include(whisper.raw)
  end
end
