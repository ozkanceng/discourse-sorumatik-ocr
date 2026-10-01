# frozen_string_literal: true

require "net/http"
require "json"
require "base64"

module SorumatikOcr
  class AiSolveController < ::ApplicationController
    include ActionController::Live

    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required

    def stream
      # 1. Plugin & Feature enablement check
      unless SiteSetting.gemini_ocr_enabled && SiteSetting.gemini_ai_solve_enabled
        return render_json_error("AI solve feature is disabled on the server", status: 503)
      end

      # 2. Rate limiting per user or per IP
      limit = SiteSetting.gemini_ai_solve_rate_limit_per_minute.to_i
      limit = 15 if limit <= 0
      if current_user
        RateLimiter.new(current_user, "sorumatik_ai_solve", limit, 1.minute).performed!
      else
        RateLimiter.new(nil, "sorumatik_ai_solve_#{request.remote_ip}", limit, 1.minute).performed!
      end

      # 4. Resolve API key
      api_key = SiteSetting.gemini_ocr_api_key.presence || ENV["GEMINI_API_KEY"]
      if api_key.blank?
        Rails.logger.error("[Sorumatik AI Solve] Gemini API key is missing.")
        return render_json_error(I18n.t("sorumatik_ocr.api_key_missing"), status: 500)
      end

      # 5. Resolve Topic
      topic_id = params[:topic_id].to_i
      if topic_id <= 0
        return render_json_error(I18n.t("sorumatik_ocr.topic_missing"), status: 400)
      end

      topic = Topic.find_by(id: topic_id)
      if topic.blank?
        return render_json_error("Topic not found", status: 404)
      end

      # 6. Resolve Question Text & Image
      first_post = topic.first_post
      question_text = params[:question_text].presence ||
                      params[:prompt].presence ||
                      params[:text].presence ||
                      first_post&.raw.to_s

      if question_text.blank?
        return render_json_error("Question text is empty", status: 400)
      end

      # Optional image handling
      image_data_parts = []
      image_param = params[:image]
      if image_param.present?
        image_bytes = if image_param.respond_to?(:tempfile)
                        image_param.tempfile.read
                      elsif image_param.respond_to?(:read)
                        image_param.read
                      else
                        image_param.to_s
                      end
        if image_bytes.present?
          mime_type = image_param.respond_to?(:content_type) && image_param.content_type.present? ? image_param.content_type : "image/jpeg"
          image_data_parts << {
            inline_data: {
              mime_type: mime_type,
              data: Base64.strict_encode64(image_bytes)
            }
          }
        end
      end

      # 7. Model & System Instruction
      model = SiteSetting.gemini_ai_solve_model.presence || "gemini-2.5-flash"
      system_instruction_text = SiteSetting.gemini_ai_solve_system_prompt.presence ||
        "Sen Sorumatik platformunda uzman, pedagojik formasyona sahip kıdemli bir öğretmensin. Öğrencilerin sorduğu soruları adım adım, anlaşılır, cesaretlendirici ve eğitici bir dille açıkla. Matematiksel formülleri $...$ veya $$...$$ içine al. Gereksiz giriş-çıkış lafı yapmadan doğrudan soru çözümüne odaklan."

      contents_parts = []
      contents_parts.concat(image_data_parts) if image_data_parts.any?
      contents_parts << { text: question_text }

      payload = {
        contents: [
          {
            parts: contents_parts
          }
        ],
        systemInstruction: {
          parts: [{ text: system_instruction_text }]
        },
        generationConfig: {
          temperature: 0.3,
          maxOutputTokens: 16384
        }
      }

      # 8. Setup SSE Response Headers (Bypass proxy buffering and avoid Content-Length termination)
      response.headers["Content-Type"] = "text/event-stream; charset=utf-8"
      response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
      response.headers["X-Accel-Buffering"] = "no"
      response.headers["Transfer-Encoding"] = "chunked"
      response.headers.delete("Content-Length")

      # Immediately flush an initial comment to establish the streaming connection
      response.stream.write(": stream-open\n\n")

      # 9. Connect to Google Gemini Streaming API (SSE mode)
      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{model}:streamGenerateContent?alt=sse&key=#{api_key}")
      full_solution = +""

      begin
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 120) do |http|
          req = Net::HTTP::Post.new(uri.request_uri)
          req["Content-Type"] = "application/json"
          req.body = payload.to_json

          http.request(req) do |gemini_res|
            if gemini_res.code.to_i != 200
              err_msg = "Gemini API returned status #{gemini_res.code}"
              Rails.logger.error("[Sorumatik AI Solve] #{err_msg}")
              response.stream.write("data: #{ { error: err_msg }.to_json }\n\n")
              return
            end

            sse_buffer = +""
            gemini_res.read_body do |chunk|
              sse_buffer << chunk
              while (line_end = sse_buffer.index("\n"))
                line = sse_buffer.slice!(0..line_end).strip
                next if line.empty? || line.start_with?(":")

                if line.start_with?("data:")
                  raw_json = line.sub(/\Adata:\s*/, "").strip
                  next if raw_json.empty?

                  begin
                    parsed_chunk = JSON.parse(raw_json)
                    candidates = parsed_chunk["candidates"] || []
                    first_cand = candidates.first || {}
                    finish_reason = first_cand["finishReason"]
                    if finish_reason.present? && finish_reason != "STOP"
                      Rails.logger.warn("[Sorumatik AI Solve] Gemini finished with reason: #{finish_reason}")
                    end
                    parts = first_cand.dig("content", "parts") || []
                    delta_text = parts.reject { |p| p["thought"] == true }.map { |p| p["text"] }.compact.join("")

                    if delta_text.present?
                      full_solution << delta_text
                      # Stream delta to client in real-time
                      response.stream.write("data: #{ { delta: delta_text, topic_id: topic_id }.to_json }\n\n")
                    end
                  rescue JSON::ParserError
                    # Non-fatal chunk parsing error
                  end
                end
              end
            end
          end
        end

        # 10. Persist solution to Discourse Forum via PostCreator
        post_id = nil
        post_number = nil
        if full_solution.strip.present?
          bot_username = SiteSetting.gemini_ai_solve_bot_username.presence || "sorumatik_ai"
          bot_user = User.find_by_username(bot_username) || Discourse.system_user

          begin
            created_post = PostCreator.create!(
              bot_user,
              topic_id: topic_id,
              raw: full_solution.strip,
              skip_validations: true
            )
            if created_post
              post_id = created_post.id
              post_number = created_post.post_number
              begin
                topic = created_post.topic
                if topic
                  topic.custom_fields["ai_solve_handled"] = "true"
                  topic.save_custom_fields(true)
                  DiscourseTagging.tag_topic_by_names(topic, Discourse.system_user.guardian, ["soru-cozumu"], append: true) if defined?(DiscourseTagging)
                end
              rescue => tag_err
                Rails.logger.warn("[Sorumatik AI Solve] Failed to tag topic: #{tag_err.message}")
              end
            end
          rescue => post_err
            Rails.logger.error("[Sorumatik AI Solve] Failed to create post: #{post_err.class}: #{post_err.message}")
          end
        end

        # 11. Send completion event to client
        completion_payload = {
          done: true,
          topic_id: topic_id,
          post_id: post_id,
          post_number: post_number,
          full_length: full_solution.length
        }
        response.stream.write("data: #{completion_payload.to_json}\n\n")

      rescue RateLimiter::LimitExceeded
        response.stream.write("data: #{ { error: I18n.t("sorumatik_ocr.rate_limited") }.to_json }\n\n")
      rescue => e
        Rails.logger.error("[Sorumatik AI Solve] Exception: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        response.stream.write("data: #{ { error: "An error occurred during AI streaming" }.to_json }\n\n")
      ensure
        response.stream.close
      end
    end
  end
end
