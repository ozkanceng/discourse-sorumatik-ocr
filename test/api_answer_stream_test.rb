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
