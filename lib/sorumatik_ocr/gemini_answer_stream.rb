# frozen_string_literal: true

require "net/http"
require "json"
require "timeout"

module SorumatikOcr
  # A single provider attempt after visible output. Only pre-output transient
  # failures may retry, using the same key and the same absolute deadline.
  class GeminiAnswerStream
    class Failure < StandardError
      attr_reader :code, :retryable, :retry_after
      def initialize(code, retryable: false, retry_after: nil)
        @code, @retryable, @retry_after = code, retryable, retry_after
        super(code)
      end
    end

    def initialize(model:, api_key:, payload:, deadline:, metrics:)
      @model, @api_key, @payload, @deadline, @metrics = model, api_key, payload, deadline, metrics
    end

    def remaining
      seconds = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Failure.new("generation_timeout") if seconds <= 0
      seconds
    end

    def each_delta
      visible = false
      attempts = 0
      begin
        attempts += 1
        @metrics["provider_attempts"] = attempts
        finished = false
        uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{@model}:streamGenerateContent?alt=sse")
        Timeout.timeout(remaining) do
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: [10, remaining].min, read_timeout: remaining) do |http|
            request = Net::HTTP::Post.new(uri.request_uri)
            request["Content-Type"] = "application/json"
            request["x-goog-api-key"] = @api_key
            request.body = JSON.generate(@payload)
            http.request(request) do |response|
              status = response.code.to_i
              @metrics["provider_status"] = status
              unless status == 200
                raise Failure.new("provider_#{status}", retryable: status == 429 || status >= 500,
                                  retry_after: response["retry-after"]&.to_i)
              end
              parser = Frames.new
              consume = proc do |data|
                remaining
                usage = data["usageMetadata"]
                @metrics["tokens"] = usage.slice("promptTokenCount", "candidatesTokenCount", "thoughtsTokenCount") if usage
                raise Failure.new("provider_error") if data["error"]
                raise Failure.new("blocked") if data.dig("promptFeedback", "blockReason")
                candidate = data.fetch("candidates", []).first
                next unless candidate
                finish = candidate["finishReason"]
                raise Failure.new("incomplete_#{finish.downcase}") if finish && finish != "STOP"
                candidate.dig("content", "parts").to_a.each do |part|
                  next if part["thought"] || part["text"].to_s.empty?
                  visible = true
                  yield part["text"]
                end
                finished = true if finish == "STOP"
              end
              response.read_body { |bytes| parser.feed(bytes, &consume) }
              parser.finish(&consume)
            end
          end
        end
        raise Failure.new("incomplete_stream") unless finished && visible
      rescue Failure, Timeout::Error, IOError, EOFError, SystemCallError, SocketError => e
        remaining # Classify exhaustion consistently, including partial streams.
        transient = e.is_a?(Failure) ? e.retryable : true
        if !visible && attempts < 2 && transient
          delay = e.is_a?(Failure) && e.retry_after.to_i > 0 ? e.retry_after : 0.5 + rand
          raise Failure.new("generation_timeout") if delay >= remaining
          sleep(delay)
          retry
        end
        raise(e.is_a?(Failure) ? e : Failure.new("provider_connection_failed"))
      end
    end

    # Network chunks may split UTF-8 characters or SSE lines. Decode only a
    # complete event and never swallow malformed provider data as success.
    class Frames
      def initialize
        @buffer = +"".b
      end

      def feed(bytes)
        @buffer << bytes.b
        while (match = @buffer.match(/\r?\n\r?\n/))
          frame = @buffer.slice!(0, match.end(0))
          decode(frame) { |data| yield data }
        end
      end

      def finish
        decode(@buffer) { |data| yield data } unless @buffer.empty?
        @buffer.clear
      end

      def decode(frame)
        text = frame.dup.force_encoding(Encoding::UTF_8)
        raise Failure.new("invalid_utf8") unless text.valid_encoding?
        data = text.lines.map { |line| line.sub(/^data:\s?/, "").strip if line.start_with?("data:") }.compact.join("\n")
        return if data.empty? || data == "[DONE]"
        yield JSON.parse(data)
      rescue JSON::ParserError
        raise Failure.new("invalid_stream_frame")
      end
    end
  end
end
