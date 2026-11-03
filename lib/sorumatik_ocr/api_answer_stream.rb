# frozen_string_literal: true

require_relative "gemini_answer_stream"

module SorumatikOcr
  # The same Gemini stream, sent through the Sorumatik API (api.sorumatik.co)
  # over the Docker bridge instead of straight to Google. The API relays
  # Gemini's request and SSE events unchanged, so parsing, retries and error
  # codes are GeminiAnswerStream's. The API adds capacity limits, metrics and
  # the single Gemini key; it does not see Cloudflare.
  class ApiAnswerStream < GeminiAnswerStream
    def initialize(model:, payload:, deadline:, metrics:, user_id:, request_id:, service_token:, base_url:, charge: nil)
      super(model: model, api_key: nil, payload: payload, deadline: deadline, metrics: metrics)
      @user_id, @request_id, @service_token, @base_url = user_id, request_id, service_token, base_url
      @charge = charge # { feature:, key:, tier: } for questions asked from the new app
    end

    # The asker is out of Brain Energy or daily answers: final, never retried or sent to Gemini.
    def failure_for(status, response)
      if status == 429
        body = +""
        response.read_body { |chunk| body << chunk } rescue nil
        message = (JSON.parse(body).dig("error", "message") rescue nil)
        return Failure.new("quota_exceeded") if message == "quota_exceeded"
      end
      super
    end

    def endpoint
      URI("#{@base_url.to_s.chomp("/")}/internal/v1/ai/models/#{@model}:streamGenerateContent")
    end

    def authorize(request)
      request["X-Sorumatik-Service-Token"] = @service_token.to_s
      request["X-Sorumatik-User"] = @user_id.to_s
      request["X-Sorumatik-Feature"] = "forum_answer"
      request["X-Request-ID"] = @request_id.to_s
      return unless @charge

      request["X-Sorumatik-Charge-Feature"] = @charge[:feature].to_s
      request["X-Sorumatik-Charge-Key"] = @charge[:key].to_s
      request["X-Sorumatik-Tier"] = @charge[:tier].to_s if @charge[:tier]
    end
  end
end
