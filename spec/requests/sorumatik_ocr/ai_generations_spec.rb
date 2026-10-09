# frozen_string_literal: true
require "rails_helper"

describe "AI generation API" do
  fab!(:user)
  fab!(:other_user) { Fabricate(:user) }
  fab!(:source) { Fabricate(:post, user: user) }

  before do
    SiteSetting.gemini_ocr_enabled = true
    SiteSetting.gemini_ai_solve_enabled = true
    Jobs.stubs(:enqueue)
    sign_in(user)
  end

  it "returns one identity when start is repeated and exposes authenticated status" do
    2.times { post "/sorumatik/ai-generations.json", params: { topic_id: source.topic_id, source_post_id: source.id } }
    expect(response.status).to eq(202)
    id = response.parsed_body["generation_id"]
    expect(SorumatikOcr::AiGeneration.where(source_post_id: source.id).count).to eq(1)
    get "/sorumatik/ai-generations/#{id}.json"
    expect(response.status).to eq(200)
    expect(response.parsed_body["source_post_id"]).to eq(source.id)
  end

  it "denies another user's generation even when the topic is public" do
    record = SorumatikOcr::AnswerGeneration.start!(source)
    sign_in(other_user)
    get "/sorumatik/ai-generations/#{record.generation_id}.json"
    expect(response.status).to eq(403)
    post "/sorumatik/ai-generations.json", params: { topic_id: source.topic_id, source_post_id: source.id }
    expect(response.status).to eq(403)
  end

  it "does not accept a source from another topic" do
    post "/sorumatik/ai-generations.json", params: { topic_id: source.topic_id + 1, source_post_id: source.id }
    expect(response.status).to eq(404)
  end

  it "stops exposing a generation after its source is deleted" do
    record = SorumatikOcr::AnswerGeneration.start!(source)
    source.update_columns(deleted_at: Time.current)
    get "/sorumatik/ai-generations/#{record.generation_id}.json"
    expect(response.status).to eq(404)
  end

  it "does not resume an older failed answer after a newer answer completes" do
    older = SorumatikOcr::AnswerGeneration.start!(source)
    older.update!(state: "failed")
    followup = Fabricate(:post, topic: source.topic, user: user)
    newer = SorumatikOcr::AnswerGeneration.start!(followup)
    newer.update!(state: "completed")
    get "/t/#{source.topic_id}.json"
    expect(response.status).to eq(200)
    expect(response.parsed_body["sorumatik_pending_generation"]).to be_nil
  end
  it "exposes source-specific status only to its owner" do
    record = SorumatikOcr::AnswerGeneration.start!(source)
    get "/sorumatik/ai-generations/by-source/#{source.id}.json"
    expect(response.status).to eq(200)
    expect(response.parsed_body["generation_id"]).to eq(record.generation_id)
    sign_in(other_user)
    get "/sorumatik/ai-generations/by-source/#{source.id}.json"
    expect(response.status).to eq(403)
  end

  it "refuses server generation for a versioned mobile source" do
    source.custom_fields["client_edge_solve"] = "true"
    source.custom_fields["mobile_answer_protocol"] = "2"
    source.save_custom_fields
    post "/sorumatik/ai-generations.json", params: { topic_id: source.topic_id, source_post_id: source.id }
    expect(response.status).to eq(409)
    expect(response.parsed_body["error"]).to eq("client_owned_source")
    expect(SorumatikOcr::AiGeneration.where(source_post_id: source.id)).to be_empty
  end

  it "rejects a hash mismatch before importing content" do
    post "/sorumatik/save-solution.json", params: { topic_id: source.topic_id, source_post_id: source.id,
      content: "Cevap", content_sha256: "wrong" }
    expect(response.status).to eq(409)
    expect(response.parsed_body["error"]).to eq("content_hash_mismatch")
    expect(SorumatikOcr::AiGeneration.where(source_post_id: source.id)).to be_empty
  end

  it "returns the verified post for identical imports and rejects changed content" do
    bot = Fabricate(:user, username: "sorumatik_ai")
    SiteSetting.gemini_ai_solve_bot_username = bot.username
    raw = "Türkçe 👩🏽‍💻 tam cevap"
    params = { topic_id: source.topic_id, source_post_id: source.id,
      content: raw, content_sha256: Digest::SHA256.hexdigest(raw) }
    SorumatikOcr::GeminiAnswerStream.expects(:new).never
    post "/sorumatik/save-solution.json", params: params
    expect(response.status).to eq(200)
    first = response.parsed_body
    expect(first).to include("state" => "completed", "raw" => raw,
      "source_post_id" => source.id, "content_sha256" => params[:content_sha256])
    post "/sorumatik/save-solution.json", params: params
    expect(response.status).to eq(200)
    expect(response.parsed_body).to include("post_id" => first["post_id"], "duplicate" => true)
    post "/sorumatik/save-solution.json", params: params.merge(content: "Değişmiş cevap", content_sha256: nil)
    expect(response.status).to eq(409)
    expect(Post.find(first["post_id"]).raw).to eq(raw)
    expect(source.topic.posts.where(user_id: bot.id).count).to eq(1)
  end

  it "returns 202 with durable text when saving fails and exposes save status" do
    bot = Fabricate(:user, username: "sorumatik_ai")
    SiteSetting.gemini_ai_solve_bot_username = bot.username
    SorumatikOcr::GeminiAnswerStream.expects(:new).never
    PostCreator.any_instance.expects(:create!).once.raises(StandardError, "database unavailable")
    Jobs.stubs(:enqueue_in)
    post "/sorumatik/save-solution.json", params: { topic_id: source.topic_id,
      source_post_id: source.id, content: "Hazır cevap korunur" }
    expect(response.status).to eq(202)
    expect(response.parsed_body).to include("state" => "persisting", "raw" => "Hazır cevap korunur", "post_id" => nil)
    get "/sorumatik/ai-generations/#{response.parsed_body['generation_id']}.json"
    expect(response.status).to eq(200)
    expect(response.parsed_body["raw"]).to eq("Hazır cevap korunur")
  end

  it "does not let another user save an answer to this source" do
    sign_in(other_user)
    post "/sorumatik/save-solution.json", params: { topic_id: source.topic_id,
      source_post_id: source.id, content: "Başkasının cevabı" }
    expect(response.status).to eq(403)
    expect(SorumatikOcr::AiGeneration.where(source_post_id: source.id)).to be_empty
  end

end
