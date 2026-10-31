# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module SorumatikOcr
  class AiController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    include ActionController::Live

    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required

    COACH_SYSTEM_INSTRUCTION = <<~PROMPT
      Sen Türkiye'nin en başarılı YKS ve LGS derece koçusun.
      Öğrencilere şefkatli, son derece motive edici, disiplinli, analitik ve stratejik bir yaklaşımla rehberlik ediyorsun.

      Temel Prensiplerin:
      1. Sokratik Sorgulama: Doğrudan kestirme yanıt vermek yerine öğrencinin kendi çalışma verimini analiz etmesini sağla.
      2. Net Odaklı Strateji: Deneme netleri, MEB kazanımları, ÖSYM çıkmış sorular ve zaman yönetimi odaklı ol.
      3. Matematiksel İfadeler: Formülleri $...$ satır içi veya $$...$$ blok LaTeX ile yaz.
      4. Pomodoro ve Aralıklarla Tekrar: Bilimsel öğrenme tekniklerini tavsiye et.
      5. Samimi & Pozitif Dil: Öğrenciye ismiyle hitap et, asla umutsuzluğa düşürme.
    PROMPT

    SOLVER_SYSTEM_INSTRUCTION = <<~PROMPT
      Sen uzman bir öğretmen ve pedagojik soru çözüm asistanısın.
      Soruya sadece kuru bir cevap vermek yerine öğrenciye konuyu öğreten, adım adım rehberlik eden bir çözüm sun.

      Format:
      1. **Özet & Verilenler:** Soru ne istiyor, verilenler neler?
      2. **Adım Adım Çözüm:** Tüm matematiksel formülleri $...$ ve $$...$$ LaTeX standartlarında yaz.
      3. **Tuzak & Dikkat Noktası:** Öğrenciler bu soruda genellikle nerede hata yapar?
      4. **Doğru Seçenek ve Sağlama:** Doğru cevabın sağlaması.
    PROMPT

    PLAN_SYSTEM_INSTRUCTION = <<~PROMPT
      Sen üst düzey bir akademik planlama uzmanısın.
      Öğrencinin hedef sınavı, netleri ve haftalık çalışma saatlerine göre 7 günlük (Pazartesi-Pazar) dengeli,
      gerçekçi ve verimli bir çalışma takvimi oluştur.
      Yanıtını SADECE geçerli bir JSON bloğu olarak döndür.
    PROMPT

    # POST /sorumatik/ai/generate
    def generate
      ensure_authenticated_user! || return
      ensure_plugin_and_key! || return
      enforce_rate_limit! || return

      prompt = params[:prompt].to_s
      if prompt.length > MAX_PROMPT_CHARS
        return render_json_error("İstek metni çok uzun (maksimum #{MAX_PROMPT_CHARS} karakter)", status: 413)
      end

      system_instruction = params[:system_instruction].presence || params[:systemInstruction]
      if system_instruction.present? && system_instruction.to_s.length > MAX_SYSTEM_INSTRUCTION_CHARS
        return render_json_error("Sistem yönergesi çok uzun", status: 413)
      end

      default_tools_model = SiteSetting.respond_to?(:gemini_ai_tools_model) ? SiteSetting.gemini_ai_tools_model.presence : nil
      model = SecurityPolicy.resolve_text_model(
        params[:model],
        site_setting: SiteSetting,
        setting_model: default_tools_model,
        fallback: "gemini-2.5-flash"
      )
      media_parts = params[:media_parts] || params[:mediaParts] || []
      is_json = params[:is_json].to_s == "true" || params[:isJson].to_s == "true"
      thinking_level = (params[:thinking_level].presence || params[:thinkingLevel].presence).to_s.strip.downcase
      client_contents = normalize_client_contents(params[:contents])

      if prompt.blank? && media_parts.blank? && client_contents.blank?
        return render_json_error("Prompt veya medya gereklidir", status: 400)
      end

      parts = []
      if media_parts.is_a?(Array)
        if media_parts.length > MAX_MEDIA_PARTS
          return render_json_error("En fazla #{MAX_MEDIA_PARTS} medya dosyası gönderilebilir", status: 400)
        end

        media_parts.each do |part|
          if part.is_a?(Hash) && (part["inlineData"] || part[:inlineData])
            data_hash = part["inlineData"] || part[:inlineData]
            raw_data = (data_hash["data"] || data_hash[:data]).to_s
            if raw_data.blank? || raw_data.bytesize > MAX_CLIENT_PART_BYTES
              return render_json_error("Medya dosyası boyutu sınırı aşıyor (maksimum 5 MB)", status: 413)
            end
            raw_mime = (data_hash["mimeType"] || data_hash[:mimeType] || "image/jpeg").to_s.strip.downcase
            unless SecurityPolicy::ALLOWED_MEDIA_MIME_TYPES.include?(raw_mime)
              return render_json_error("Desteklenmeyen medya türü", status: 400)
            end
            normalized_mime = raw_mime == "image/jpg" ? "image/jpeg" : raw_mime
            parts << {
              inline_data: {
                mime_type: normalized_mime,
                data: raw_data
              }
            }
          end
        end
      end
      parts << { text: prompt } if prompt.present?

      generation_config = {
        maxOutputTokens: resolve_max_output_tokens(model, is_json: is_json, thinking_level: thinking_level)
      }

      if is_json
        generation_config[:responseMimeType] = "application/json"
      end

      apply_thinking_config!(generation_config, model, thinking_level)

      payload = {
        contents: client_contents.presence || [{ parts: parts }],
        generationConfig: generation_config
      }

      if system_instruction.present?
        payload[:systemInstruction] = { parts: [{ text: system_instruction.to_s }] }
      end

      api_key = resolve_api_key
      is_stream = params[:stream].to_s == "true" || request.headers["Accept"].to_s.include?("text/event-stream")

      if is_stream
        stream_gemini_sse(model, api_key, payload)
      else
        response_json = call_gemini_sync(model, api_key, payload)
        if response_json[:success]
          render json: {
            success: true,
            model: model,
            text: response_json[:text]
          }
        else
          render_json_error(response_json[:error], status: 502)
        end
      end
    end

    # POST /sorumatik/ai/tts
    def tts
      ensure_tts_authorized! || return
      ensure_plugin_and_key! || return
      enforce_tts_rate_limit! || return

      text = params[:text].to_s.strip
      if text.blank?
        return render_json_error("Metin gereklidir", status: 400)
      end
      if text.length > MAX_TTS_TEXT_CHARS
        return render_json_error("Seslendirilecek metin çok uzun (maksimum #{MAX_TTS_TEXT_CHARS} karakter)", status: 413)
      end

      raw_voice = params[:voice].presence || "Kore"
      voice = raw_voice.to_s.match?(SecurityPolicy::TTS_VOICE_REGEX) ? raw_voice.to_s : "Kore"
      api_key = resolve_api_key
      model = SecurityPolicy.resolve_tts_model(
        params[:model],
        site_setting: SiteSetting,
        fallback: "gemini-3.8-flash-lite-tts"
      )

      payload = {
        model: model,
        input: [{
          type: "user_input",
          content: [{
            type: "text",
            text: text
          }]
        }],
        response_format: {
          type: "audio"
        },
        generation_config: {
          speech_config: [
            { voice: voice }
          ]
        }
      }

      uri = URI("https://generativelanguage.googleapis.com/v1beta/interactions")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 30

      req = Net::HTTP::Post.new(uri.request_uri, {
        "Content-Type" => "application/json",
        "x-goog-api-key" => api_key
      })
      req.body = payload.to_json

      res = http.request(req)
      if res.code.to_i == 200
        parsed = JSON.parse(res.body)
        steps = parsed["steps"] || []
        audio_step = steps.reverse.find { |s| s["type"] == "model_output" }
        audio_content = audio_step&.dig("content")&.find { |c| c["type"] == "audio" }
        audio_base64 = audio_content&.dig("data")

        if audio_base64.present?
          clean_base64 = sanitize_wav_base64(audio_base64)
          render json: {
            success: true,
            mime_type: "audio/wav",
            audio_base64: clean_base64,
            model: model
          }
        else
          render_json_error("Ses verisi üretilemedi", status: 500)
        end
      else
        Rails.logger.error("[Sorumatik AI TTS] Google TTS #{res.code}: #{res.body.to_s[0..200]}")
        render_json_error("Google TTS servisi yanıt vermedi (Kod: #{res.code})", status: 502)
      end
    rescue => e
      Rails.logger.error("[Sorumatik AI TTS] Bağlantı hatası: #{e.class}: #{e.message}")
      render_json_error("TTS servisi şu anda yanıt veremiyor", status: 500)
    end

    # POST /sorumatik/ai/coach
    def coach
      ensure_authenticated_user! || return
      ensure_plugin_and_key! || return
      enforce_rate_limit! || return

      messages = params[:messages] || []
      user_prompt = (params[:prompt].presence || (messages.is_a?(Array) ? messages.last&.dig(:text) : nil)).to_s

      if user_prompt.blank? && messages.blank?
        return render_json_error("Prompt veya mesaj geçmişi gereklidir", status: 400)
      end
      if user_prompt.length > MAX_PROMPT_CHARS
        return render_json_error("İstek metni çok uzun", status: 413)
      end

      contents = []
      if messages.is_a?(Array) && messages.any?
        messages.last(MAX_CLIENT_CONTENTS).each do |msg|
          next unless msg.is_a?(Hash)
          role = (msg[:role] == "user" || msg["role"] == "user") ? "user" : "model"
          txt = (msg[:text] || msg["text"]).to_s[0, 10_000]
          contents << { role: role, parts: [{ text: txt }] } if txt.present?
        end
      else
        contents << { role: "user", parts: [{ text: user_prompt }] }
      end

      if contents.blank?
        return render_json_error("Geçerli mesaj içeriği bulunamadı", status: 400)
      end

      payload = {
        contents: contents,
        systemInstruction: {
          parts: [{ text: COACH_SYSTEM_INSTRUCTION }]
        },
        generationConfig: {
          maxOutputTokens: 2048
        }
      }

      api_key = resolve_api_key
      default_tools_model = SiteSetting.respond_to?(:gemini_ai_tools_model) ? SiteSetting.gemini_ai_tools_model.presence : nil
      model = SecurityPolicy.resolve_text_model(nil, site_setting: SiteSetting, setting_model: default_tools_model, fallback: "gemini-2.5-flash")

      is_stream = params[:stream].to_s == "true" || request.headers["Accept"].to_s.include?("text/event-stream")

      if is_stream
        stream_gemini_sse(model, api_key, payload)
      else
        response_json = call_gemini_sync(model, api_key, payload)
        if response_json[:success]
          render json: {
            success: true,
            model: model,
            text: response_json[:text]
          }
        else
          render_json_error(response_json[:error], status: 502)
        end
      end
    end

    # POST /sorumatik/ai/solve
    def solve
      ensure_authenticated_user! || return
      ensure_plugin_and_key! || return
      enforce_rate_limit! || return

      question_text = params[:question_text].to_s
      image_base64 = params[:image_base64].to_s
      raw_mime = (params[:image_mime_type].presence || "image/jpeg").to_s.strip.downcase

      if question_text.blank? && image_base64.blank?
        return render_json_error("Soru metni veya görseli gereklidir", status: 400)
      end
      if question_text.length > MAX_PROMPT_CHARS
        return render_json_error("Soru metni çok uzun", status: 413)
      end

      parts = []
      parts << { text: question_text } if question_text.present?
      if image_base64.present?
        if image_base64.bytesize > MAX_CLIENT_PART_BYTES
          return render_json_error("Görsel boyutu sınırı aşıyor (maksimum 5 MB)", status: 413)
        end
        unless SecurityPolicy::ALLOWED_OCR_MIME_TYPES.include?(raw_mime)
          return render_json_error("Desteklenmeyen görsel formatı", status: 400)
        end
        image_mime = raw_mime == "image/jpg" ? "image/jpeg" : raw_mime
        parts << {
          inline_data: {
            mime_type: image_mime,
            data: image_base64
          }
        }
      end

      payload = {
        contents: [{ parts: parts }],
        systemInstruction: {
          parts: [{ text: SOLVER_SYSTEM_INSTRUCTION }]
        },
        generationConfig: {
          maxOutputTokens: 3000
        }
      }

      api_key = resolve_api_key
      default_solve_model = SiteSetting.respond_to?(:gemini_ai_solve_model) ? SiteSetting.gemini_ai_solve_model.presence : nil
      model = SecurityPolicy.resolve_text_model(nil, site_setting: SiteSetting, setting_model: default_solve_model, fallback: "gemini-2.5-flash")

      res = call_gemini_sync(model, api_key, payload)
      if res[:success]
        render json: {
          success: true,
          model: model,
          solution: res[:text]
        }
      else
        render_json_error(res[:error], status: 502)
      end
    end

    # POST /sorumatik/ai/plan
    def plan
      ensure_authenticated_user! || return
      ensure_plugin_and_key! || return
      enforce_rate_limit! || return

      exam = (params[:exam].presence || "YKS Sayısal").to_s.strip[0, 80]
      target_rank = (params[:target_rank] || 10_000).to_i.clamp(1, 5_000_000)
      daily_hours = (params[:daily_hours] || 5).to_f.clamp(0.5, 18.0)
      weak_subjects = Array(params[:weak_subjects]).first(25).map { |s| s.to_s.strip[0, 80] }.reject(&:blank?)

      prompt = <<~USER_P
        Hedef Sınav: #{exam}
        Hedef Derece: İlk #{target_rank}
        Günlük Çalışma Süresi: #{daily_hours} saat
        Eksik Konular: #{weak_subjects.join(', ')}

        Lütfen aşağıdaki JSON şemasına birebir uyan 7 günlük bir ders programı üret:
        {
          "title": "Kişiselleştirilmiş Çalışma Planı",
          "exam": "#{exam}",
          "days": [
            {
              "dayName": "Pazartesi",
              "tasks": [
                { "subject": "Matematik", "topic": "Türev Geometrik Yorum", "minutes": 90, "type": "soru" }
              ]
            }
          ]
        }
      USER_P

      payload = {
        contents: [{ parts: [{ text: prompt }] }],
        systemInstruction: {
          parts: [{ text: PLAN_SYSTEM_INSTRUCTION }]
        },
        generationConfig: {
          maxOutputTokens: 4000,
          responseMimeType: "application/json"
        }
      }

      api_key = resolve_api_key
      default_tools_model = SiteSetting.respond_to?(:gemini_ai_tools_model) ? SiteSetting.gemini_ai_tools_model.presence : nil
      model = SecurityPolicy.resolve_text_model(nil, site_setting: SiteSetting, setting_model: default_tools_model, fallback: "gemini-2.5-flash")

      res = call_gemini_sync(model, api_key, payload)
      if res[:success]
        render json: {
          success: true,
          model: model,
          plan_raw: res[:text]
        }
      else
        render_json_error(res[:error], status: 502)
      end
    end

    private

    MAX_CLIENT_CONTENTS = 24
    MAX_CLIENT_PART_BYTES = 7 * 1024 * 1024
    MAX_MEDIA_PARTS = 4
    MAX_PROMPT_CHARS = 20_000
    MAX_SYSTEM_INSTRUCTION_CHARS = 10_000
    MAX_TTS_TEXT_CHARS = 2_500
    ALLOWED_THINKING_LEVELS = %w[default minimal low medium high].freeze

    # Multi-turn question solving sends the reconstructed topic history. Roles are
    # validated here so a client cannot fabricate a "model" turn to steer answers.
    def normalize_client_contents(raw_contents)
      contents = raw_contents.is_a?(Array) ? raw_contents.first(MAX_CLIENT_CONTENTS) : []
      normalized = []
      media_count = 0
      contents.each do |turn|
        next unless turn.is_a?(Hash)
        parts = turn["parts"] || turn[:parts]
        next unless parts.is_a?(Array)
        role = (turn["role"] || turn[:role]).to_s
        next unless %w[user model].include?(role)
        cleaned = []
        parts.each do |part|
          next unless part.is_a?(Hash)
          data = part["inlineData"] || part[:inlineData] || part["inline_data"] || part[:inline_data]
          if data.is_a?(Hash)
            next if media_count >= MAX_MEDIA_PARTS
            encoded = (data["data"] || data[:data]).to_s
            next if encoded.blank? || encoded.bytesize > MAX_CLIENT_PART_BYTES
            raw_mime = (data["mimeType"] || data[:mimeType] || data["mime_type"] || data[:mime_type] || "image/jpeg").to_s.strip.downcase
            next unless SecurityPolicy::ALLOWED_MEDIA_MIME_TYPES.include?(raw_mime)
            mime = raw_mime == "image/jpg" ? "image/jpeg" : raw_mime
            media_count += 1
            cleaned << { inline_data: { mime_type: mime, data: encoded } }
          else
            text = (part["text"] || part[:text]).to_s[0, MAX_PROMPT_CHARS]
            next if text.blank?
            cleaned << { text: text }
          end
        end
        next if cleaned.blank?
        normalized << { role: role, parts: cleaned }
      end
      normalized
    end

    def ensure_authenticated_user!
      unless SecurityPolicy.active_user?(current_user)
        render_json_error(I18n.t("sorumatik_ocr.auth_required", default: "Giriş yapmanız gerekmektedir"), status: 401)
        return false
      end
      ensure_same_origin!
    end

    def ensure_tts_authorized!
      unless SecurityPolicy.active_user?(current_user) || SecurityPolicy.valid_mobile_client?(request)
        render_json_error(I18n.t("sorumatik_ocr.auth_required", default: "Giriş yapmanız gerekmektedir"), status: 401)
        return false
      end
      ensure_same_origin!
    end

    def ensure_same_origin!
      unless SecurityPolicy.same_origin_request?(request, current_user: current_user)
        render_json_error("Geçersiz istek kaynağı (CSRF koruması)", status: 403)
        return false
      end
      true
    end

    def ensure_plugin_and_key!
      unless SiteSetting.gemini_ocr_enabled
        render_json_error("Yapay zeka servisi şu anda devre dışı", status: 503)
        return false
      end

      if resolve_api_key.blank?
        Rails.logger.error("[Sorumatik AI Proxy] Gemini API key bulunamadı!")
        render_json_error("Sunucu yapay zeka yapılandırma hatası: API key eksik", status: 500)
        return false
      end

      true
    end

    def enforce_rate_limit!
      raw_limit = SiteSetting.respond_to?(:gemini_ai_rate_limit_per_minute) ? SiteSetting.gemini_ai_rate_limit_per_minute.to_i : 30
      limit = raw_limit <= 0 ? 30 : [raw_limit, 120].min
      if current_user
        RateLimiter.new(current_user, "sorumatik_ai_proxy", limit, 1.minute).performed!
        RateLimiter.new(current_user, "sorumatik_ai_proxy_daily", 500, 1.day).performed!
      elsif request.remote_ip.present?
        RateLimiter.new(nil, "sorumatik_ai_proxy_#{request.remote_ip}", 10, 1.minute, global: true).performed!
      end
      true
    rescue RateLimiter::LimitExceeded
      render_json_error("Çok fazla istek gönderildi. Lütfen biraz bekleyin.", status: 429)
      false
    end

    def enforce_tts_rate_limit!
      if SecurityPolicy.active_user?(current_user)
        RateLimiter.new(current_user, "sorumatik_ai_tts_min", 20, 1.minute).performed!
        RateLimiter.new(current_user, "sorumatik_ai_tts_day", 250, 1.day).performed!
      else
        ip = request.remote_ip.presence || "unknown"
        RateLimiter.new(nil, "sorumatik_ai_tts_ip_min_#{ip}", 8, 1.minute, global: true).performed!
        RateLimiter.new(nil, "sorumatik_ai_tts_ip_day_#{ip}", 50, 1.day, global: true).performed!
      end
      true
    rescue RateLimiter::LimitExceeded
      render_json_error("Çok fazla seslendirme isteği gönderildi. Lütfen biraz bekleyin.", status: 429)
      false
    end

    def resolve_api_key
      SorumatikOcr.resolve_api_key
    end

    def resolve_max_output_tokens(model, is_json: false, thinking_level: "default")
      m = model.to_s.strip.downcase
      lvl = ALLOWED_THINKING_LEVELS.include?(thinking_level.to_s.strip.downcase) ? thinking_level.to_s.strip.downcase : "default"
      if m.start_with?("gemini-2.5", "gemini-3")
        if %w[minimal low].include?(lvl)
          is_json ? 16_384 : 12_288
        else
          32_768
        end
      else
        is_json ? 8_192 : 4_096
      end
    end

    def apply_thinking_config!(generation_config, model, raw_level)
      level = ALLOWED_THINKING_LEVELS.include?(raw_level) ? raw_level : "default"

      if model.to_s.start_with?("gemini-2.5")
        return if level == "default"
        budget = case level
                 when "minimal" then 0
                 when "low" then 1024
                 when "medium" then 2048
                 else 4096
                 end
        generation_config[:thinkingConfig] = { thinkingBudget: budget }
      elsif model.to_s.start_with?("gemini-3")
        return if level == "default"
        effective_level = level
        if effective_level == "minimal" && model.to_s.match?(/gemini-3\.(?:[78]|1)/)
          effective_level = "low"
        end
        generation_config[:thinkingConfig] = { thinkingLevel: effective_level }
      end
    end

    def call_gemini_sync(model, api_key, payload)
      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 120

      req = Net::HTTP::Post.new(uri.request_uri, {
        "Content-Type" => "application/json",
        "x-goog-api-key" => api_key
      })
      req.body = payload.to_json

      res = http.request(req)
      if res.code.to_i == 200
        parsed = JSON.parse(res.body)
        candidates = parsed["candidates"] || []
        parts = candidates.first&.dig("content", "parts") || []
        text = parts.reject { |p| p["thought"] == true }.map { |p| p["text"] }.compact.join("\n")
        { success: true, text: text }
      else
        Rails.logger.error("[Sorumatik AI Proxy] Gemini #{res.code}: #{res.body.to_s[0..200]}")
        { success: false, error: "Google AI yanıt vermedi (Kod: #{res.code})" }
      end
    rescue => e
      Rails.logger.error("[Sorumatik AI Proxy] Bağlantı hatası: #{e.class}: #{e.message}")
      { success: false, error: "Yapay zeka servisine bağlanılamadı" }
    end

    def stream_gemini_sse(model, api_key, payload)
      slot = ProxyCapacity.acquire
      unless slot
        response.headers["Retry-After"] = "5"
        return render json: { success: false, error: "proxy_busy" }, status: 503
      end

      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{model}:streamGenerateContent?alt=sse")

      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 180) do |http|
        req = Net::HTTP::Post.new(uri.request_uri, {
          "Content-Type" => "application/json",
          "x-goog-api-key" => api_key
        })
        req.body = payload.to_json

        http.request(req) do |res|
          if res.code.to_i != 200
            response.stream.write("data: #{ { error: "Gemini SSE hatası: #{res.code}" }.to_json }\n\n")
            return
          end

          res.read_body do |chunk|
            response.stream.write(chunk)
          end
        end
      end
    rescue => e
      Rails.logger.error("[Sorumatik AI Proxy SSE Hatası] #{e.class}: #{e.message}")
      response.stream.write("data: #{ { error: "Akış bağlantısı kesildi" }.to_json }\n\n")
    ensure
      if slot
        ProxyCapacity.release(slot)
        response.stream.close rescue nil
      end
    end

    def sanitize_wav_base64(raw_base64)
      return raw_base64 if raw_base64.blank?
      begin
        bytes = Base64.decode64(raw_base64)
        return raw_base64 if bytes.bytesize < 44

        # If it's a RIFF WAVE file, extract only the PCM audio from the data chunk
        data = bytes
        sample_rate = 24_000
        channels = 1
        bits_per_sample = 16

        while data.bytesize >= 12 && data[0, 4] == "RIFF" && data[8, 4] == "WAVE"
          offset = 12
          found_data = false
          while offset + 8 <= data.bytesize
            chunk_id = data[offset, 4]
            chunk_size = data[offset + 4, 4].unpack1("V")
            offset += 8
            if chunk_id == "fmt " && chunk_size >= 16
              channels = data[offset + 2, 2].unpack1("v") rescue 1
              sample_rate = data[offset + 4, 4].unpack1("V") rescue 24_000
              bits_per_sample = data[offset + 14, 2].unpack1("v") rescue 16
            elsif chunk_id == "data"
              end_offset = [offset + chunk_size, data.bytesize].min
              data = data[offset...end_offset]
              found_data = true
              break
            end
            offset += chunk_size + (chunk_size % 2)
          end
          break unless found_data
        end

        pcm_len = data.bytesize & ~1
        return raw_base64 if pcm_len < 4
        pcm = data[0...pcm_len]

        # Apply gentle 10ms ramp-out (240 samples at 24kHz) to eliminate end pops / cızırtı
        samples = pcm.unpack("s<*")
        ramp = [240, samples.length / 4].min
        if ramp > 0
          ramp.times do |i|
            factor = i.to_f / ramp
            idx = samples.length - 1 - i
            samples[idx] = (samples[idx] * factor).round
          end
        end
        clean_pcm = samples.pack("s<*")

        # Repack into a single clean RIFF WAV without any trailing C2PA/manifest chunks
        data_size = clean_pcm.bytesize
        bytes_per_sample = (bits_per_sample / 8).clamp(1, 4)
        byte_rate = sample_rate * channels * bytes_per_sample
        block_align = channels * bytes_per_sample
        clean_wav = ["RIFF", 36 + data_size, "WAVE", "fmt ", 16, 1, channels, sample_rate,
                     byte_rate, block_align, bits_per_sample,
                     "data", data_size].pack("A4VA4A4VvvVVvvA4V") + clean_pcm
        Base64.strict_encode64(clean_wav)
      rescue => e
        Rails.logger.warn("[Sorumatik AI TTS] sanitize_wav_base64 fallback: #{e.message}")
        raw_base64
      end
    end
  end
end
