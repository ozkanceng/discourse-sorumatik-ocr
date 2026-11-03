# frozen_string_literal: true
require "minitest/autorun"
require "json"
require "net/http"
require_relative "../lib/sorumatik_ocr/api_answer_stream"
require_relative "../lib/sorumatik_ocr/rollout_flags"

class ApiAnswerStreamTest < Minitest::Test
  Response = Struct.new(:code, :chunks, :headers) do
    def [](key); (headers || {})[key]; end
    def read_body; chunks.each { |chunk| yield chunk }; end
  end
  User = Struct.new(:id, :username)

  class Settings
    def initialize(values); @values = values; end
    def respond_to_missing?(name, _ = false); @values.key?(name); end
    def method_missing(name, *args); @values.key?(name) ? @values[name] : super; end
  end

  def frame(text, finish: "STOP")
    "data: #{JSON.generate(candidates: [{ content: { parts: [{ text: text }] }, finishReason: finish }])}\n\n"
  end

  def test_streams_through_the_api_with_service_headers
    calls = []
    reply = Response.new("200", [": ping\n\n", frame("Cevap 4.")])
    transport = Object.new
    transport.define_singleton_method(:request) do |request, &block|
      calls << request
      block.call(reply)
    end
    started = nil
    stream = SorumatikOcr::ApiAnswerStream.new(
      model: "gemini-3.1-flash-lite", payload: { contents: [] }, metrics: {},
      deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5,
      user_id: 42, request_id: "gen-1", service_token: "tok", base_url: "http://172.17.0.1:8000/")
    text = +""
    Net::HTTP.stub(:start, ->(host, port, **opts, &block) { started = [host, port, opts[:use_ssl]]; block.call(transport) }) do
      stream.each_delta { |delta| text << delta }
    end
    assert_equal "Cevap 4.", text
    assert_equal ["172.17.0.1", 8000, false], started
    request = calls.first
    assert_equal "/internal/v1/ai/models/gemini-3.1-flash-lite:streamGenerateContent", request.path
    assert_equal "tok", request["X-Sorumatik-Service-Token"]
    assert_equal "42", request["X-Sorumatik-User"]
    assert_equal "gen-1", request["X-Request-ID"]
    assert_nil request["x-goog-api-key"]
  end

  def test_busy_api_is_retried_once_like_gemini
    responses = [Response.new("503", [], { "retry-after" => "1" }), Response.new("200", [frame("ok")])]
    transport = Object.new
    transport.define_singleton_method(:request) { |_r, &block| block.call(responses.shift) }
    metrics = {}
    stream = SorumatikOcr::ApiAnswerStream.new(model: "gemini-3.1-flash-lite", payload: {}, metrics: metrics,
      deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5, user_id: 1, request_id: "g",
      service_token: "t", base_url: "http://api")
    stream.define_singleton_method(:sleep) { |_| }
    Net::HTTP.stub(:start, ->(*_a, **_o, &block) { block.call(transport) }) { stream.each_delta { |_| } }
    assert_equal 2, metrics["provider_attempts"]
  end

  def test_rollout_buckets_are_stable_and_beta_wins
    user = User.new(7, "Dersnotu")
    refute SorumatikOcr::RolloutFlags.enabled?("answer_api", user, percent: 0)
    assert SorumatikOcr::RolloutFlags.enabled?("answer_api", user, percent: 100)
    assert SorumatikOcr::RolloutFlags.enabled?("answer_api", user, percent: 0, beta_usernames: "qa|dersnotu")
    refute SorumatikOcr::RolloutFlags.enabled?("answer_api", nil, percent: 50)
    bucket = SorumatikOcr::RolloutFlags.bucket("answer_api", 7)
    assert_equal bucket < 50, SorumatikOcr::RolloutFlags.enabled?("answer_api", user, percent: 50)
  end

  def test_answer_backend_needs_api_mode_and_a_token
    user = User.new(7, "alice")
    on = { sorumatik_answer_backend: "api", sorumatik_api_service_token: "t", sorumatik_answer_api_percent: 100,
           sorumatik_api_beta_usernames: "", sorumatik_api_base_url: "" }
    assert SorumatikOcr::AnswerBackend.api_for?(user, site_setting: Settings.new(on))
    refute SorumatikOcr::AnswerBackend.api_for?(user, site_setting: Settings.new(on.merge(sorumatik_answer_backend: "gemini")))
    refute SorumatikOcr::AnswerBackend.api_for?(user, site_setting: Settings.new(on.merge(sorumatik_api_service_token: " ")))
    refute SorumatikOcr::AnswerBackend.api_for?(user, site_setting: Settings.new(on.merge(sorumatik_answer_api_percent: 0)))
    refute SorumatikOcr::AnswerBackend.api_for?(user, site_setting: Settings.new({}))
    assert_equal "http://172.17.0.1:8000", SorumatikOcr::AnswerBackend.base_url(site_setting: Settings.new(on))
  end
end

class ApiChargeAndBackendTest < Minitest::Test
  Response = ApiAnswerStreamTest::Response
  Settings = ApiAnswerStreamTest::Settings
  User = ApiAnswerStreamTest::User
  Req = Struct.new(:headers)
  Post = Struct.new(:id, :post_number, :topic, :custom_fields)
  Topic = Struct.new(:first_post)

  def stream(charge: nil)
    SorumatikOcr::ApiAnswerStream.new(model: "gemini-3.1-flash-lite", payload: {}, metrics: {},
      deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5, user_id: 9, request_id: "g",
      service_token: "t", base_url: "http://api", charge: charge)
  end

  def call(stream, responses)
    calls = []
    transport = Object.new
    transport.define_singleton_method(:request) { |r, &block| calls << r; block.call(responses.shift) }
    stream.define_singleton_method(:sleep) { |_| }
    Net::HTTP.stub(:start, ->(*_a, **_o, &block) { block.call(transport) }) { stream.each_delta { |_| } }
    calls
  end

  def test_quota_exceeded_is_final_and_not_retried
    body = JSON.generate(error: { code: 429, message: "quota_exceeded" })
    responses = [Response.new("429", [body])]
    error = assert_raises(SorumatikOcr::GeminiAnswerStream::Failure) { call(stream, responses) }
    assert_equal "quota_exceeded", error.code
    refute error.retryable
  end

  def test_charge_headers
    reply = Response.new("200", ["data: #{JSON.generate(candidates: [{ content: { parts: [{ text: "x" }] }, finishReason: "STOP" }])}\n\n"])
    calls = call(stream(charge: { feature: "ask_question", key: "qa:post:5", tier: "premium" }), [reply])
    assert_equal "ask_question", calls.first["X-Sorumatik-Charge-Feature"]
    assert_equal "qa:post:5", calls.first["X-Sorumatik-Charge-Key"]
    assert_equal "premium", calls.first["X-Sorumatik-Tier"]
  end

  def test_only_app_topics_are_charged
    first = Post.new(5, 1, nil, { "sorumatik_ai_backend" => "api" })
    first.topic = Topic.new(first)
    assert_equal({ feature: "ask_question", key: "qa:post:5", tier: nil }, SorumatikOcr::AnswerBackend.charge_for(first))
    reply = Post.new(6, 3, Topic.new(first), {})
    assert_equal "follow_up", SorumatikOcr::AnswerBackend.charge_for(reply)[:feature]
    web = Post.new(7, 1, nil, {})
    web.topic = Topic.new(web)
    assert_nil SorumatikOcr::AnswerBackend.charge_for(web)
  end

  def test_app_backend_block_and_build_gate
    on = { sorumatik_app_api_features: "tools|ocr", sorumatik_app_api_percent: 100, sorumatik_api_beta_usernames: "",
           sorumatik_app_quota_authority: "server", sorumatik_app_api_base_url: "https://api.sorumatik.co",
           sorumatik_api_min_app_build: 0 }
    block = SorumatikOcr::AppBackend.for_user(User.new(3, "a"), site_setting: Settings.new(on))
    assert_equal "api", block[:features]["tools"]
    assert_equal "forum", block[:features]["tts"]
    assert_equal "server", block[:quota_authority]
    anonymous = SorumatikOcr::AppBackend.for_user(nil, site_setting: Settings.new(on))
    assert_equal "forum", anonymous[:features]["tools"]
    assert_equal "device", anonymous[:quota_authority]
    off = SorumatikOcr::AppBackend.for_user(User.new(3, "a"), site_setting: Settings.new(on.merge(sorumatik_app_api_percent: 0)))
    assert_equal "forum", off[:features]["ocr"]
    gate = Settings.new(on.merge(sorumatik_api_min_app_build: 120))
    refute SorumatikOcr::AppBackend.proxy_closed_for?(Req.new({ "X-Sorumatik-App-Build" => "119" }), site_setting: gate)
    assert SorumatikOcr::AppBackend.proxy_closed_for?(Req.new({ "X-Sorumatik-App-Build" => "120" }), site_setting: gate)
    refute SorumatikOcr::AppBackend.proxy_closed_for?(Req.new({}), site_setting: gate)
    refute SorumatikOcr::AppBackend.proxy_closed_for?(Req.new({ "X-Sorumatik-App-Build" => "999" }), site_setting: Settings.new(on))
  end
end
