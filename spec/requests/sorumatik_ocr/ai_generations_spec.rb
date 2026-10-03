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
end
