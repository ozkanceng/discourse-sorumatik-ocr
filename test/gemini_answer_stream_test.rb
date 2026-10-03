# frozen_string_literal: true
require "minitest/autorun"
require_relative "../lib/sorumatik_ocr/gemini_answer_stream"

class GeminiAnswerStreamTest < Minitest::Test
  Stream = SorumatikOcr::GeminiAnswerStream
  Response = Struct.new(:code, :chunks, :headers) do
    def [](key); (headers || {})[key]; end
    def read_body
      chunks.each { |chunk| chunk.is_a?(Exception) ? raise(chunk) : yield(chunk) }
    end
  end

  def frame(text = "Çözüm: ığüşöç", finish: "STOP", thought: false)
    parts = [{ text: text, thought: thought }]
    "data: #{JSON.generate(candidates: [{ content: { parts: parts }, finishReason: finish }], usageMetadata: { thoughtsTokenCount: 12 })}\n\n"
  end

  def run_stream(responses, deadline: 3, &callback)
    metrics = {}
    requests = []
    transport = Object.new
    transport.define_singleton_method(:request) do |request, &block|
      requests << request
      block.call(responses.shift || raise("Unexpected extra provider request"))
    end
    provider = Stream.new(model: "gemini-2.5-flash", api_key: "test-key", payload: {},
                          deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline, metrics: metrics)
    provider.define_singleton_method(:sleep) { |_| } # No wall-clock backoff in unit tests.
    text = +""
    Net::HTTP.stub(:start, ->(*_args, &block) { block.call(transport) }) do
      provider.each_delta { |delta| text << delta; callback.call(delta) if callback }
    end
    [text, metrics, requests]
  end

  def test_split_utf8_and_thought_filtering
    bytes = (frame("private reasoning", finish: nil, thought: true) + frame).bytes.map { |b| b.chr }
    text, metrics, requests = run_stream([Response.new("200", bytes)])
    assert_equal "Çözüm: ığüşöç", text
    assert_equal 12, metrics.dig("tokens", "thoughtsTokenCount")
    assert_equal "test-key", requests.first["x-goog-api-key"]
    refute_includes requests.first.path, "test-key"
  end

  def test_one_transient_retry_before_output_uses_same_key
    _, metrics, requests = run_stream([Response.new("429", []), Response.new("200", [frame])])
    assert_equal 2, metrics["provider_attempts"]
    assert_equal ["test-key", "test-key"], requests.map { |r| r["x-goog-api-key"] }
  end

  def test_no_retry_after_partial_text
    emitted = []
    responses = [Response.new("200", [frame("partial", finish: nil), EOFError.new("disconnected")]), Response.new("200", [frame])]
    error = assert_raises(Stream::Failure) { run_stream(responses) { |delta| emitted << delta } }
    assert_equal ["partial"], emitted
    assert_equal 1, responses.length
    assert_equal "provider_connection_failed", error.code
  end

  def test_eof_without_stop_is_not_success
    error = assert_raises(Stream::Failure) { run_stream([Response.new("200", [frame("partial", finish: nil)])]) }
    assert_equal "incomplete_stream", error.code
  end

  def test_token_limit_is_not_success
    error = assert_raises(Stream::Failure) { run_stream([Response.new("200", [frame("partial", finish: "MAX_TOKENS")])]) }
    assert_equal "incomplete_max_tokens", error.code
  end

  def test_thought_only_stop_is_not_an_answer
    error = assert_raises(Stream::Failure) { run_stream([Response.new("200", [frame("secret", thought: true)])]) }
    assert_equal "incomplete_stream", error.code
  end

  def test_authorization_errors_are_not_retried
    responses = [Response.new("403", []), Response.new("200", [frame])]
    assert_raises(Stream::Failure) { run_stream(responses) }
    assert_equal 1, responses.length
  end

  def test_transient_failure_stops_after_two_attempts
    responses = [Response.new("503", []), Response.new("503", []), Response.new("200", [frame])]
    assert_raises(Stream::Failure) { run_stream(responses) }
    assert_equal 1, responses.length
  end

  def test_retry_after_cannot_extend_absolute_deadline
    responses = [Response.new("429", [], { "retry-after" => "10" }), Response.new("200", [frame])]
    error = assert_raises(Stream::Failure) { run_stream(responses, deadline: 0.1) }
    assert_equal "generation_timeout", error.code
    assert_equal 1, responses.length
  end

  def test_malformed_frame_cannot_succeed
    error = assert_raises(Stream::Failure) { run_stream([Response.new("200", ["data: {broken}\n\n"])]) }
    assert_equal "invalid_stream_frame", error.code
  end
end
