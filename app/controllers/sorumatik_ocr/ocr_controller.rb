# frozen_string_literal: true

require "net/http"
require "json"
require "base64"

module SorumatikOcr
  class OcrController < ::ApplicationController
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required

    DEFAULT_FALLBACK_OCR_MODEL = "gemini-3.1-flash-lite"

    SYSTEM_PROMPT = <<~PROMPT
      You are an expert multilingual exam & STEM OCR assistant. Transcribe the exam question in the image verbatim in its EXACT ORIGINAL LANGUAGE (Turkish, English, Spanish, French, German, Arabic, Indonesian, etc.). NEVER translate the question into another language.

      CRITICAL RULES:
      1. STRICT SEPARATION OF MATH AND NATURAL-LANGUAGE TEXT:
         - Wrap ONLY mathematical formulas, equations, variables, and symbolic expressions inside $...$.
         - NEVER wrap natural-language words or sentences inside $...$ (e.g. "fonksiyonu veriliyor", "olduğuna göre", "is given by", "dada la función", "¿Cuál es el valor?").
         - Correct: $f(x) = \\frac{x^2 - 4}{\\sqrt{x + 2}}$ fonksiyonu veriliyor.
         - Correct: Dada la función $f(x) = x^2 - 4x + 7$, ¿cuál es su valor mínimo?
         - Incorrect: $f(x) = \\frac{x^2 - 4}{\\sqrt{x + 2}} fonksiyonu veriliyor.$ (NEVER put prose words inside $...$!)
      2. WRAP ALL LATEX COMMANDS IN $:
         - Every LaTeX command (\\lim, \\frac, \\sqrt, \\int, \\sum, \\sin, \\cos, etc.) in the stem or choices MUST be enclosed in $...$.
         - Correct: Buna göre, $\\lim_{x \\to 2} f(x)$ ifadesinin değeri kaçtır?
      3. MULTIPLE-CHOICE OPTIONS:
         - Put each choice on its own line with an uppercase letter and closing parenthesis:
           A) ...
           B) ...
           C) ...
           D) ...
           E) ...
         - Keep the option label and its expression on the SAME line (e.g. `D) $2\\sqrt{2}$`, never split across lines).
      4. MULTILINGUAL CHARACTERS & MATH SYMBOLS:
         - Preserve all language-specific characters and punctuation verbatim:
           * Turkish: ç, ğ, ı, ö, ş, ü, İ, Ş, Ğ, Ü, Ö, Ç
           * Spanish / European: ¿, ¡, ñ, Ñ, á, é, í, ó, ú, ü, à, è, ê, ä, ö, ß
           * Non-Latin scripts (Arabic, Cyrillic, etc.) verbatim as printed.
         - Convert mathematical Unicode symbols to LaTeX inside $...$:
           × → \\times, ÷ → \\div, ≤ → \\leq, ≥ → \\geq, ≠ → \\neq, √ → \\sqrt{}, π → \\pi, ∞ → \\infty
         - Write fractions as \\frac{numerator}{denominator}.
      5. CLEAN OUTPUT ONLY:
         - Strip leading question numbers/headers ("Soru 12", "SORU 3", "Question 5", "Problem 2", "Pregunta 4", "Ejercicio 1", "Aufgabe 3", "Exercice 2").
         - Do NOT solve, explain, translate, or add introductory commentary. Output ONLY the clean question text.
         - Mark unreadable parts with [?].
    PROMPT

    MAX_OCR_IMAGE_BYTES = 5 * 1024 * 1024
    MAX_OCR_BASE64_CHARS = 7 * 1024 * 1024

    def extract
      # 1. Authorization: active user session OR valid mobile client header (never unverified User-Api-Key)
      return unless ensure_authorized!

      # 2. Check if plugin is enabled
      unless SiteSetting.gemini_ocr_enabled
        return render_json_error("Gemini OCR plugin is disabled", status: 503)
      end

      # 3. Rate limiting (authenticated user vs strict anonymous IP minute/daily quota)
      is_authenticated = SecurityPolicy.active_user?(current_user)
      if is_authenticated
        raw_limit = SiteSetting.gemini_ocr_rate_limit_per_minute.to_i
        limit = raw_limit <= 0 ? 30 : [raw_limit, 60].min
        RateLimiter.new(current_user, "sorumatik_ocr", limit, 1.minute).performed!
        RateLimiter.new(current_user, "sorumatik_ocr_daily", 300, 1.day).performed!
      else
        ip = request.remote_ip.presence || "unknown"
        RateLimiter.new(nil, "sorumatik_ocr_ip_min_#{ip}", 8, 1.minute, global: true).performed!
        RateLimiter.new(nil, "sorumatik_ocr_ip_day_#{ip}", 40, 1.day, global: true).performed!
      end

      # 4. Resolve API key securely (from SiteSetting or ENV)
      api_key = SorumatikOcr.resolve_api_key
      if api_key.blank?
        Rails.logger.error("[Sorumatik OCR] Gemini API key is missing in SiteSetting / ENV.")
        return render_json_error(I18n.t("sorumatik_ocr.api_key_missing"), status: 500)
      end

      # 5. Handle incoming image file or base64 data with strict 5 MB & MIME validation
      image_param = params[:image]
      image_base64_param = params[:image_base64].presence || params[:data].presence

      base64_data = nil
      mime_type = "image/jpeg"

      if image_param.present?
        if image_param.respond_to?(:size) && image_param.size.to_i > MAX_OCR_IMAGE_BYTES
          return render_json_error("Görsel boyutu çok büyük (maksimum 5 MB)", status: 413)
        end

        image_bytes = if image_param.respond_to?(:tempfile)
                        image_param.tempfile.read(MAX_OCR_IMAGE_BYTES + 1)
                      elsif image_param.respond_to?(:read)
                        image_param.read(MAX_OCR_IMAGE_BYTES + 1)
                      else
                        image_param.to_s
                      end

        if image_bytes.blank?
          return render_json_error(I18n.t("sorumatik_ocr.image_missing"), status: 400)
        end
        if image_bytes.bytesize > MAX_OCR_IMAGE_BYTES
          return render_json_error("Görsel boyutu çok büyük (maksimum 5 MB)", status: 413)
        end

        mime_type = if image_param.respond_to?(:content_type) && image_param.content_type.present?
                      image_param.content_type
                    else
                      "image/jpeg"
                    end

        base64_data = Base64.strict_encode64(image_bytes)
      elsif image_base64_param.present?
        raw_b64 = image_base64_param.to_s
        if raw_b64.bytesize > MAX_OCR_BASE64_CHARS
          return render_json_error("Görsel boyutu çok büyük (maksimum 5 MB)", status: 413)
        end
        if raw_b64 =~ /\Adata:(image\/[a-zA-Z0-9.+-]+);base64,(.+)\z/m
          mime_type = $1
          base64_data = $2
        else
          mime_type = params[:image_mime_type].presence || params[:mime_type].presence || "image/jpeg"
          base64_data = raw_b64
        end
      else
        return render_json_error(I18n.t("sorumatik_ocr.image_missing"), status: 400)
      end

      raw_mime = mime_type.to_s.strip.downcase
      unless SecurityPolicy::ALLOWED_OCR_MIME_TYPES.include?(raw_mime)
        return render_json_error("Desteklenmeyen görsel formatı (JPEG, PNG veya WebP yükleyin)", status: 400)
      end
      mime_type = raw_mime == "image/jpg" ? "image/jpeg" : raw_mime

      mode = (params[:type] || params[:mode] || "question").to_s.downcase
      # Prevent arbitrary LLM prompt override abuse on OCR endpoint (only staff may pass custom_prompt)
      is_staff = is_authenticated && current_user.respond_to?(:staff?) && current_user.staff?
      custom_prompt = is_staff ? params[:prompt].to_s.strip[0, 1_000].presence : nil
      branch = params[:branch].to_s.gsub(/[^\p{L}\p{N}\s\/.-]/, "").strip[0, 60].presence

      if mode == "timetable"
        default_timetable_prompt = <<~TPROMPT
          Sen bir MEB (Milli Eğitim Bakanlığı) haftalık ders programı çizelgesi çözümleme uzmanısın.
          Görseldeki haftalık öğretmen veya sınıf ders dağıtım tablosunu satır satır ve sütun sütun analiz et.

          Kurallar:
          1. Günler: Pazartesi=1, Salı=2, Çarşamba=3, Perşembe=4, Cuma=5.
          2. Ders Saatleri: 1, 2, 3, 4, 5, 6, 7, 8 ... sıralı periyot numaralarıdır.
          3. Sınıf adı (örn: "12-A", "9/B") ve ders adını (örn: "Matematik", "Fizik") çıkar.
          #{branch ? "4. Öğretmenin branşı \"#{branch}\" olarak bilinmektedir. Ders adı yazmayan hücrelerde bunu kullan." : ""}
          5. Eğer zil saatleri varsa "08:30" - "09:10" olarak startTime ve endTime ekle.
          6. SADECE saf geçerli bir JSON dizisi (array) döndür:
          [{"dayOfWeek": 1, "periodNumber": 1, "className": "12-A", "subjectName": "Matematik", "startTime": "08:30", "endTime": "09:10"}]
        TPROMPT

        prompt_text = custom_prompt || default_timetable_prompt
        generation_cfg = {
          maxOutputTokens: 2048,
          responseMimeType: "application/json"
        }
        system_instruction = nil
      else
        prompt_text = custom_prompt || "Extract the exam/math question from this image accurately as plain text and $...$ LaTeX in its exact original language (do NOT translate)."
        generation_cfg = {
          maxOutputTokens: 2048
        }
        system_instruction = {
          parts: [{ text: SYSTEM_PROMPT }]
        }
      end

      # 6. Resolve Gemini OCR model strictly through SecurityPolicy allowlist
      selected_model = SecurityPolicy.resolve_ocr_model(
        params[:model].presence || params[:engine],
        site_setting: SiteSetting,
        fallback: DEFAULT_FALLBACK_OCR_MODEL
      )

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
        generationConfig: generation_cfg
      }
      payload[:systemInstruction] = system_instruction if system_instruction

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      res = post_gemini_ocr_request(selected_model, api_key, payload)
      if res.code.to_i == 404 && selected_model != DEFAULT_FALLBACK_OCR_MODEL
        Rails.logger.warn("[Sorumatik OCR] Model #{selected_model} returned 404; retrying with #{DEFAULT_FALLBACK_OCR_MODEL}")
        selected_model = DEFAULT_FALLBACK_OCR_MODEL
        res = post_gemini_ocr_request(selected_model, api_key, payload)
      end
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

      # 7. Return format based on mode
      if mode == "timetable"
        clean_json = raw_text.gsub(/```json\s*/i, "").gsub(/```/, "").strip
        begin
          timetable_data = JSON.parse(clean_json)
          render json: timetable_data
        rescue JSON::ParserError => je
          Rails.logger.error("[Sorumatik OCR] Timetable JSON parse error: #{je.message}")
          render json: { error: "Failed to parse timetable JSON", raw: raw_text }, status: 502
        end
      else
        render json: {
          success: true,
          engine: selected_model,
          question_latex: raw_text,
          raw_text: raw_text,
          title: "Soru",
          confidence: 95,
          needs_review: false,
          duration_ms: duration_ms
        }
      end
    rescue RateLimiter::LimitExceeded
      render_json_error(I18n.t("sorumatik_ocr.rate_limited"), status: 429)
    rescue => e
      Rails.logger.error("[Sorumatik OCR] Exception in OCR: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      render_json_error("Internal error during OCR", status: 500)
    end

    private

    def post_gemini_ocr_request(model_name, api_key, payload)
      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{model_name}:generateContent")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 25

      req = Net::HTTP::Post.new(uri.request_uri, {
        "Content-Type" => "application/json",
        "x-goog-api-key" => api_key
      })
      req.body = payload.to_json
      http.request(req)
    end

    def ensure_authorized!
      unless SecurityPolicy.active_user?(current_user) || SecurityPolicy.valid_mobile_client?(request)
        render_json_error(I18n.t("sorumatik_ocr.auth_required", default: "Bu işlem için oturum açmanız veya geçerli bir istemci kullanmanız gerekmektedir"), status: 401)
        return false
      end
      unless SecurityPolicy.same_origin_request?(request, current_user: current_user)
        render_json_error("Geçersiz istek kaynağı (CSRF koruması)", status: 403)
        return false
      end
      true
    end
  end
end
