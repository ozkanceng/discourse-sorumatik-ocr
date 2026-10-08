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
      ensure_authorized! || return
      ensure_plugin_and_key! || return
      enforce_rate_limit! || return

      prompt = params[:prompt].to_s
      system_instruction = params[:system_instruction].presence || params[:systemInstruction]
      model = params[:model].presence || (SiteSetting.respond_to?(:gemini_ai_tools_model) ? SiteSetting.gemini_ai_tools_model.presence : nil) || "gemini-2.5-flash"
      media_parts = params[:media_parts] || params[:mediaParts] || []
      is_json = params[:is_json].to_s == "true" || params[:isJson].to_s == "true"
      temperature = (params[:temperature] || 0.3).to_f
      thinking_budget = params[:thinking_budget] || params[:thinkingBudget]

      if prompt.blank? && media_parts.blank?
        return render_json_error("Prompt veya medya gereklidir", status: 400)
      end

      parts = []
      if media_parts.is_a?(Array)
        media_parts.each do |part|
          if part.is_a?(Hash) && (part["inlineData"] || part[:inlineData])
            data_hash = part["inlineData"] || part[:inlineData]
            parts << {
              inline_data: {
                mime_type: data_hash["mimeType"] || data_hash[:mimeType] || "image/jpeg",
                data: data_hash["data"] || data_hash[:data]
              }
            }
          end
        end
      end
      parts << { text: prompt } if prompt.present?

      payload = {
        contents: [{ parts: parts }],
        generationConfig: {
          temperature: temperature,
          maxOutputTokens: resolve_max_output_tokens(model)
        }
      }

      if system_instruction.present?
        payload[:systemInstruction] = { parts: [{ text: system_instruction }] }
      end

      if is_json
        payload[:generationConfig][:responseMimeType] = "application/json"
      end

      budget = thinking_budget.present? ? thinking_budget.to_i : 0
      budget = 0 if budget < 0
      if model.to_s.start_with?("gemini-2.5")
        payload[:generationConfig][:thinkingConfig] = {
          thinkingBudget: budget
        }
      elsif model.to_s.start_with?("gemini-3")
        payload[:generationConfig][:thinkingConfig] = {
          thinkingLevel: budget == 0 ? "minimal" : "low"
        }
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
      ensure_authorized! || return
      ensure_plugin_and_key! || return
      enforce_rate_limit! || return

      text = params[:text].to_s.strip
      if text.blank?
        return render_json_error("Metin gereklidir", status: 400)
      end

      voice = params[:voice].presence || "Kore"
      api_key = resolve_api_key
      model = "gemini-3.8-flash-tts"

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
        audio_mime = audio_content&.dig("mime_type") || "audio/wav"

        if audio_base64.present?
          render json: {
            success: true,
            mime_type: audio_mime,
            audio_base64: audio_base64
          }
        else
          render_json_error("Ses verisi üretilemedi", status: 500)
        end
      else
        render_json_error("Google TTS servisi yanıt vermedi (Kod: #{res.code})", status: 500)
      end
    rescue => e
      render_json_error("TTS servisi bağlantı hatası: #{e.message}", status: 500)
    end

    # POST /sorumatik/ai/coach
    def coach
      ensure_authorized! || return
      ensure_plugin_and_key! || return
      enforce_rate_limit! || return

      messages = params[:messages] || []
      user_prompt = params[:prompt].presence || (messages.is_a?(Array) ? messages.last&.dig(:text) : nil)

      if user_prompt.blank? && messages.blank?
        return render_json_error("Prompt veya mesaj geçmişi gereklidir", status: 400)
      end

      contents = []
      if messages.is_a?(Array) && messages.any?
        messages.each do |msg|
          role = (msg[:role] == "user" || msg["role"] == "user") ? "user" : "model"
          txt = msg[:text] || msg["text"] || ""
          contents << { role: role, parts: [{ text: txt }] } if txt.present?
        end
      else
        contents << { role: "user", parts: [{ text: user_prompt }] }
      end

      payload = {
        contents: contents,
        systemInstruction: {
          parts: [{ text: COACH_SYSTEM_INSTRUCTION }]
        },
        generationConfig: {
          temperature: 0.7,
          maxOutputTokens: 2048
        }
      }

      api_key = resolve_api_key
      model = SiteSetting.respond_to?(:gemini_ai_tools_model) ? (SiteSetting.gemini_ai_tools_model.presence || "gemini-2.5-flash") : "gemini-2.5-flash"

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
      ensure_authorized! || return
      ensure_plugin_and_key! || return
      enforce_rate_limit! || return

      question_text = params[:question_text].to_s
      image_base64 = params[:image_base64].to_s
      image_mime = params[:image_mime_type].presence || "image/jpeg"

      if question_text.blank? && image_base64.blank?
        return render_json_error("Soru metni veya görseli gereklidir", status: 400)
      end

      parts = []
      parts << { text: question_text } if question_text.present?
      if image_base64.present?
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
          temperature: 0.2,
          maxOutputTokens: 3000
        }
      }

      api_key = resolve_api_key
      model = SiteSetting.respond_to?(:gemini_ai_solve_model) ? (SiteSetting.gemini_ai_solve_model.presence || "gemini-2.5-flash") : "gemini-2.5-flash"

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
      ensure_authorized! || return
      ensure_plugin_and_key! || return
      enforce_rate_limit! || return

      exam = params[:exam].presence || "YKS Sayısal"
      target_rank = params[:target_rank] || 10000
      daily_hours = params[:daily_hours] || 5
      weak_subjects = params[:weak_subjects] || []

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
          temperature: 0.3,
          maxOutputTokens: 4000,
          responseMimeType: "application/json"
        }
      }

      api_key = resolve_api_key
      model = SiteSetting.respond_to?(:gemini_ai_tools_model) ? (SiteSetting.gemini_ai_tools_model.presence || "gemini-2.5-flash") : "gemini-2.5-flash"

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

    def ensure_authorized!
      unless current_user.present? || request.headers["User-Api-Key"].present? || request.headers["User-Api-Client-Id"].to_s == "sorumatik_mobile_v4"
        render_json_error(I18n.t("sorumatik_ocr.auth_required", default: "Giriş yapmanız gerekmektedir"), status: 401)
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
      limit = SiteSetting.respond_to?(:gemini_ai_rate_limit_per_minute) ? SiteSetting.gemini_ai_rate_limit_per_minute.to_i : 30
      limit = 30 if limit <= 0
      if current_user
        RateLimiter.new(current_user, "sorumatik_ai_proxy", limit, 1.minute).performed!
      elsif request.remote_ip.present?
        RateLimiter.new(nil, "sorumatik_ai_proxy_#{request.remote_ip}", limit, 1.minute, global: true).performed!
      end
      true
    rescue RateLimiter::LimitExceeded
      render_json_error("Çok fazla istek gönderildi. Lütfen bir dakika bekleyin.", status: 429)
      false
    end

    def resolve_api_key
      (SiteSetting.respond_to?(:gemini_ocr_api_key) && SiteSetting.gemini_ocr_api_key.presence) || ENV["GEMINI_API_KEY"]
    end

    def resolve_max_output_tokens(model)
      m = model.to_s.downcase
      if m.include?("3.1") || m.include?("3.8") || m.include?("3-") || m.include?("pro")
        65536
      elsif m.include?("2.5")
        16384
      else
        8192
      end
    end

    def call_gemini_sync(model, api_key, payload)
      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 60

      req = Net::HTTP::Post.new(uri.request_uri, { "Content-Type" => "application/json" })
      req.body = payload.to_json

      res = http.request(req)
      if res.code.to_i == 200
        parsed = JSON.parse(res.body)
        candidates = parsed["candidates"] || []
        parts = candidates.first&.dig("content", "parts") || []
        text = parts.map { |p| p["text"] }.compact.join("\n")
        { success: true, text: text }
      else
        Rails.logger.error("[Sorumatik AI Proxy] Gemini #{res.code}: #{res.body.to_s[0..200]}")
        { success: false, error: "Google AI yanıt vermedi (Kod: #{res.code})" }
      end
    rescue => e
      Rails.logger.error("[Sorumatik AI Proxy] Bağlantı hatası: #{e.message}")
      { success: false, error: e.message }
    end

    def stream_gemini_sse(model, api_key, payload)
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{model}:streamGenerateContent?alt=sse")

      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 90) do |http|
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
      Rails.logger.error("[Sorumatik AI Proxy SSE Hatası] #{e.message}")
      response.stream.write("data: #{ { error: e.message }.to_json }\n\n")
    ensure
      response.stream.close rescue nil
    end
  end
end
