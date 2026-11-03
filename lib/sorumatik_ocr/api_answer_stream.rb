# frozen_string_literal: true

require_relative "gemini_answer_stream"

module SorumatikOcr
  # The same Gemini stream, sent through the Sorumatik API (api.sorumatik.co)
  # over the Docker bridge instead of straight to Google. The API relays
  # Gemini's request and SSE events unchanged, so parsing, retries and error
  # codes are GeminiAnswerStream's. The API adds capacity limits, metrics and
  # the single Gemini key; it does not see Cloudflare.
  class ApiAnswerStream < GeminiAnswerStream
    def initialize(model:, payload:, deadline:, metrics:, user_id:, request_id:, service_token:, base_url:)
      super(model: model, api_key: nil, payload: payload, deadline: deadline, metrics: metrics)
      @user_id, @request_id, @service_token, @base_url = user_id, request_id, service_token, base_url
    end

    def endpoint
      URI("#{@base_url.to_s.chomp("/")}/internal/v1/ai/models/#{@model}:streamGenerateContent")
    end

    def authorize(request)
      request["X-Sorumatik-Service-Token"] = @service_token.to_s
      request["X-Sorumatik-User"] = @user_id.to_s
      request["X-Sorumatik-Feature"] = "forum_answer"
      request["X-Request-ID"] = @request_id.to_s
    end
  end
end
