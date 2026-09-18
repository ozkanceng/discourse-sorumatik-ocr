# frozen_string_literal: true

require "net/http"
require "json"
require "base64"

module SorumatikOcr
  class OcrController < ::ApplicationController
    requires_login
    skip_before_action :verify_authenticity_token

    SYSTEM_PROMPT = <<~PROMPT
      Sen uzman bir matematik OCR asistanısın. Görevin görseldeki Türkçe sınav sorusunu birebir yazıya aktarmaktır.

      KURALLAR:
      1. Matematiksel ifadeleri (kesir, karekök, üs, integral, toplam, limit, türev, matris, logaritma, trigonometri vb.) standart LaTeX formatında yaz:
         - Satır içi: $...$
         - Ayrık/blok denklem: $$...$$
      2. Türkçe karakterleri koru: ç, ğ, ı, ö, ş, ü, İ, Ş, Ğ, Ü, Ö, Ç.
      3. Seçenekler varsa her birini ayrı satırda yaz:
         A) ...
         B) ...
         C) ...
         D) ...
         E) ...
      4. Soru numaralarını ("Soru 12", "SORU 3" vb.) kaldır.
      5. Sadece sorunun metnini döndür. Yorum, çözüm, açıklama veya giriş cümlesi EKLEME.
      6. Unicode sembollerini LaTeX karşılıklarına çevir:
         × → \\times, ÷ → \\div, ≤ → \\leq, ≥ → \\geq, √ → \\sqrt{}, π → \\pi, ∞ → \\infty
      7. Kesirleri \\frac{pay}{payda} olarak yaz.
      8. Bilinmeyen veya okunamayan kısımları [?] ile belirt.
    PROMPT

    def extract
      # 1. Check if plugin is enabled
      unless SiteSetting.gemini_ocr_enabled
        return render_json_error("Gemini OCR plugin is disabled", status: 503)
      end

      # 2. Rate limiting (per user)
      limit = SiteSetting.gemini_ocr_rate_limit_per_minute.to_i
      limit = 30 if limit <= 0
      RateLimiter.new(current_user, "sorumatik_ocr", limit, 1.minute).performed!

      # 3. Resolve API key (from SiteSetting or ENV)
      api_key = SiteSetting.gemini_ocr_api_key.presence || ENV["GEMINI_API_KEY"]
      if api_key.blank?
        Rails.logger.error("[Sorumatik OCR] Gemini API key is missing in SiteSetting / ENV.")
        return render_json_error(I18n.t("sorumatik_ocr.api_key_missing"), status: 500)
      end

      # 4. Handle incoming image file
      image_param = params[:image]
      if image_param.blank?
        return render_json_error(I18n.t("sorumatik_ocr.image_missing"), status: 400)
      end

      image_bytes = if image_param.respond_to?(:tempfile)
                      image_param.tempfile.read
                    elsif image_param.respond_to?(:read)
                      image_param.read
                    else
                      image_param.to_s
                    end

      if image_bytes.blank?
        return render_json_error(I18n.t("sorumatik_ocr.image_missing"), status: 400)
      end

      mime_type = if image_param.respond_to?(:content_type) && image_param.content_type.present?
                    image_param.content_type
                  else
                    "image/jpeg"
                  end

      base64_data = Base64.strict_encode64(image_bytes)
      lang = (params[:lang] || "tr").to_s.downcase
      prompt_text = lang == "tr" ? "Bu görseldeki sınav/matematik sorusunu metin ve LaTeX formatında çıkar." : "Extract the exam question in text and LaTeX."

      # 5. Build Google Gemini 2.5 Flash Lite payload with thinkingBudget: 0
      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=#{api_key}")

      payload = {
        contents: [
          {
            parts: [
              { text: prompt_text },
              {
                inline_data: {
                  mime_type: mime_type,
                  data: base64_data
                }
              }
            ]
          }
        ],
        generationConfig: {
          temperature: 0.1,
          maxOutputTokens: 2048,
          thinkingConfig: {
            thinkingBudget: 0
          }
        },
        systemInstruction: {
          parts: [
            { text: SYSTEM_PROMPT }
          ]
        }
      }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 20

      req = Net::HTTP::Post.new(uri.request_uri, { "Content-Type" => "application/json" })
      req.body = payload.to_json

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      res = http.request(req)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

      if res.code.to_i != 200
        Rails.logger.error("[Sorumatik OCR] Gemini API returned #{res.code}: #{res.body.to_s[0..300]}")
        return render_json_error(I18n.t("sorumatik_ocr.gemini_error"), status: 502)
      end

      # 6. Parse Gemini response
      parsed = JSON.parse(res.body)
      candidates = parsed["candidates"] || []
      first_candidate = candidates.first || {}
      parts = first_candidate.dig("content", "parts") || []
      raw_text = parts.map { |p| p["text"] }.compact.join("\n").strip

      if raw_text.blank?
        return render_json_error("Gemini empty response", status: 502)
      end

      # 7. Return standard format expected by mobile client
      render json: {
        success: true,
        engine: "gemini_flash_lite",
        question_latex: raw_text,
        raw_text: raw_text,
        title: "Soru",
        confidence: 95,
        needs_review: false,
        duration_ms: duration_ms
      }
    rescue RateLimiter::LimitExceeded
      render_json_error(I18n.t("sorumatik_ocr.rate_limited"), status: 429)
    rescue => e
      Rails.logger.error("[Sorumatik OCR] Exception in OCR: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      render_json_error("Internal error during OCR", status: 500)
    end
  end
end
