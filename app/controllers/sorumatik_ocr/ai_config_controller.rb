# frozen_string_literal: true

module SorumatikOcr
  class AiConfigController < ::ApplicationController
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required

    # GET /sorumatik/ai-config
    def show
      begin
        limit = 60
        if current_user
          RateLimiter.new(current_user, "sorumatik_ai_config", limit, 1.minute).performed!
        elsif request.remote_ip.present?
          RateLimiter.new(nil, "sorumatik_ai_config_#{request.remote_ip}", limit, 1.minute, global: true).performed!
        end
      rescue RateLimiter::LimitExceeded
        return render json: { success: false, error: "Rate limit exceeded" }, status: 429
      rescue => rl_err
        Rails.logger.warn("[Sorumatik AI Config] RateLimiter notice: #{rl_err.message}")
      end

      raw_tools_model = (SiteSetting.respond_to?(:gemini_ai_tools_model) && SiteSetting.gemini_ai_tools_model.presence) || "gemini-2.5-flash"
      model = SecurityPolicy.resolve_text_model(nil, site_setting: SiteSetting, setting_model: raw_tools_model, fallback: "gemini-2.5-flash")
      raw_solve_model = (SiteSetting.respond_to?(:gemini_ai_solve_model) && SiteSetting.gemini_ai_solve_model.presence) || model
      solve_model = SecurityPolicy.resolve_text_model(nil, site_setting: SiteSetting, setting_model: raw_solve_model, fallback: model)
      solve_system_prompt = (SiteSetting.respond_to?(:gemini_ai_solve_system_prompt) && SiteSetting.gemini_ai_solve_system_prompt.presence) || ""
      solve_thinking_level = (SiteSetting.respond_to?(:gemini_ai_solve_thinking_level) && SiteSetting.gemini_ai_solve_thinking_level.presence) || "default"
      ocr_model = SecurityPolicy.resolve_ocr_model(nil, site_setting: SiteSetting, fallback: "gemini-3.1-flash-lite")
      raw_doc_model = (SiteSetting.respond_to?(:gemini_document_quiz_model) && SiteSetting.gemini_document_quiz_model.presence) || model
      document_quiz_model = SecurityPolicy.resolve_text_model(nil, site_setting: SiteSetting, setting_model: raw_doc_model, fallback: model)
      tts_model = SecurityPolicy.resolve_tts_model(nil, site_setting: SiteSetting, fallback: "gemini-3.8-flash-lite-tts")
      raw_bb_model = (SiteSetting.respond_to?(:gemini_blackboard_model) && SiteSetting.gemini_blackboard_model.presence) ||
                     (SiteSetting.respond_to?(:blackboard_model) && SiteSetting.blackboard_model.presence) ||
                     "gemini-3.8-flash"
      blackboard_model = SecurityPolicy.resolve_text_model(nil, site_setting: SiteSetting, setting_model: raw_bb_model, fallback: "gemini-3.8-flash")
      blackboard_thinking_level = (SiteSetting.respond_to?(:gemini_blackboard_thinking_level) && SiteSetting.gemini_blackboard_thinking_level.presence) ||
                                  (SiteSetting.respond_to?(:blackboard_thinking_level) && SiteSetting.blackboard_thinking_level.presence) ||
                                  "low"
      ocr_enabled = SiteSetting.respond_to?(:gemini_ocr_enabled) ? SiteSetting.gemini_ocr_enabled : false
      tools_enabled = SiteSetting.respond_to?(:gemini_ai_tools_enabled) ? SiteSetting.gemini_ai_tools_enabled : true
      enabled = ocr_enabled && tools_enabled

      bot_username = SiteSetting.gemini_ai_solve_bot_username.presence || "sorumatik_ai"
      bot_user = defined?(::User) && ::User.respond_to?(:find_by_username) ? ::User.find_by_username(bot_username) : nil
      bot_display_name = bot_user&.name.presence || bot_username
      bot_avatar_url = ""
      if bot_user&.avatar_template.present?
        bot_avatar_url = bot_user.avatar_template.gsub("{size}", "120")
        bot_avatar_url = "#{Discourse.base_url}#{bot_avatar_url}" if bot_avatar_url.start_with?("/")
      end

      # SECURITY: İstemciye asla Gemini API anahtarı sızdırılmaz.
      # İstemciler her zaman sunucu proxy (/sorumatik/ai/generate, /sorumatik/ocr) üzerinden çalışmalıdır.
      render json: {
        success: true,
        mobile_answer_protocol: 3,
        server_generation: true,
        enabled: !!enabled,
        save_solution_enabled: true,
        proxy: true,
        model: model,
        solve_model: solve_model,
        solve_bot_username: bot_username,
        solve_bot_display_name: bot_display_name,
        solve_bot_avatar_url: bot_avatar_url,
        solve_system_prompt: solve_system_prompt,
        solve_thinking_level: solve_thinking_level,
        ocr_model: ocr_model,
        document_quiz_model: document_quiz_model,
        tts_model: tts_model,
        blackboard_model: blackboard_model,
        blackboard_thinking_level: blackboard_thinking_level,
        api_key: ""
      }
    rescue => err
      Rails.logger.error("[Sorumatik AI Config] Error: #{err.class}: #{err.message}")
      render json: { success: false, error: "Configuration unavailable" }, status: 500
    end

    MAX_STUDY_TITLE_CHARS = 250
    MAX_STUDY_PROMPT_CHARS = 20_000
    MAX_STUDY_CONTENT_CHARS = 60_000

    # POST /sorumatik/save-study
    def save_study
      unless SecurityPolicy.active_user?(current_user)
        return render_json_error(I18n.t("sorumatik_ocr.auth_required"), status: 401)
      end
      unless SecurityPolicy.same_origin_request?(request, current_user: current_user)
        return render_json_error("Geçersiz istek kaynağı (CSRF koruması)", status: 403)
      end

      RateLimiter.new(current_user, "sorumatik_save_study_min", 15, 1.minute).performed!
      RateLimiter.new(current_user, "sorumatik_save_study_day", 200, 1.day).performed!

      title = params[:title].to_s.strip[0, MAX_STUDY_TITLE_CHARS]
      prompt = params[:prompt].to_s.strip
      content = params[:content].to_s.strip

      if title.blank? || content.blank?
        return render_json_error("Title and content are required", status: 400)
      end
      if prompt.length > MAX_STUDY_PROMPT_CHARS || content.length > MAX_STUDY_CONTENT_CHARS
        return render_json_error("Content exceeds maximum allowed length", status: 413)
      end

      prompt = "Yapay Zeka Çalışma İsteği" if prompt.blank?
      mute_notifications = params[:mute_notifications].to_s == "true" || params[:mute_notification].to_s == "true"

      bot_username = SiteSetting.gemini_ai_solve_bot_username.presence || "sorumatik_ai"
      bot_user = User.find_by_username(bot_username) || Discourse.system_user

      # 1. Create Private Message Post #1 from current_user
      post1_opts = {
        title: title,
        raw: prompt,
        archetype: "private_message",
        target_usernames: bot_username,
        skip_validations: true,
        topic_opts: { custom_fields: { "ai_module_handled" => "true" } },
        custom_fields: { "ai_module_handled" => "true" }
      }
      post1_opts[:skip_notifications] = true if mute_notifications

      post1 = PostCreator.create!(
        current_user,
        post1_opts
      )

      topic = post1&.topic
      unless topic
        return render_json_error("Failed to create topic", status: 500)
      end

      topic.custom_fields["ai_module_handled"] = "true"
      topic.save_custom_fields(true)

      # 2. Create Post #2 from bot with the pre-generated AI content
      post2_opts = {
        topic_id: topic.id,
        raw: content,
        skip_validations: true
      }
      post2_opts[:skip_notifications] = true if mute_notifications

      post2 = PostCreator.create!(
        bot_user,
        post2_opts
      )

      # 3. If requested (e.g. document quiz), mute this topic for current_user and purge any transient notifications
      if mute_notifications
        begin
          TopicUser.change(current_user.id, topic.id, notification_level: TopicUser.notification_levels[:muted])
          Notification.where(user_id: current_user.id, topic_id: topic.id).destroy_all
        rescue => mute_err
          Rails.logger.warn("[Sorumatik Save Study] Could not mute topic: #{mute_err.message}")
        end
      end

      render json: {
        success: true,
        topic_id: topic.id,
        post_number: post2&.post_number || 2,
        created_at: topic.created_at
      }
    rescue RateLimiter::LimitExceeded
      render_json_error(I18n.t("sorumatik_ocr.rate_limited", default: "Çok fazla istek gönderildi. Lütfen biraz bekleyin."), status: 429)
    rescue => err
      Rails.logger.error("[Sorumatik Save Study] Error saving study: #{err.class}: #{err.message}")
      render_json_error("Failed to save study", status: 500)
    end

    # Compatibility import: never regenerate or acknowledge different text.
    def save_solution
      raise Discourse::NotLoggedIn unless SecurityPolicy.active_user?(current_user)
      unless SecurityPolicy.same_origin_request?(request, current_user: current_user)
        return render_json_error("Geçersiz istek kaynağı (CSRF koruması)", status: 403)
      end

      RateLimiter.new(current_user, "sorumatik_save_solution_min", 20, 1.minute).performed!

      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::NotFound unless topic
      guardian.ensure_can_see!(topic)
      source = params[:source_post_id].present? ? topic.posts.find(params[:source_post_id]) : topic.first_post
      raise Discourse::InvalidAccess unless source && source.deleted_at.nil? && source.post_type == Post.types[:regular] && source.user_id == current_user.id
      content = params[:content].to_s.gsub("\r\n", "\n").strip
      return render_json_error("Content is required", status: 400) if content.blank?
      return render_json_error("Content exceeds maximum allowed length", status: 413) if content.length > MAX_STUDY_CONTENT_CHARS
      if params[:content_sha256].present?
        raw_param = params[:content].to_s
        expected_hashes = [Digest::SHA256.hexdigest(content), Digest::SHA256.hexdigest(raw_param)]
        unless expected_hashes.include?(params[:content_sha256])
          return render json: { success: false, error: "content_hash_mismatch" }, status: 409
        end
      end
      previous = AiGeneration.find_by(source_post_id: source.id)
      generation = AnswerGeneration.import!(source, content)
      duplicate = previous && previous.post_id.present? && previous.post_id == generation.post_id
      render json: generation.snapshot.merge(success: generation.state == "completed", duplicate: !!duplicate),
             status: generation.state == "completed" ? 200 : 202
    rescue RateLimiter::LimitExceeded
      render_json_error(I18n.t("sorumatik_ocr.rate_limited", default: "Çok fazla istek gönderildi. Lütfen biraz bekleyin."), status: 429)
    rescue GeminiAnswerStream::Failure => e
      return render json: { success: false, error: e.code }, status: 409
    end

    private

    def resolve_api_key
      SorumatikOcr.resolve_api_key
    end
  end
end
