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

      api_key = (SiteSetting.respond_to?(:gemini_ocr_api_key) && SiteSetting.gemini_ocr_api_key.presence) || ENV["GEMINI_API_KEY"] || ""
      model = (SiteSetting.respond_to?(:gemini_ai_tools_model) && SiteSetting.gemini_ai_tools_model.presence) || "gemini-2.5-flash"
      ocr_model = (SiteSetting.respond_to?(:gemini_ocr_model) && SiteSetting.gemini_ocr_model.presence) || "gemini-2.5-flash-lite"
      document_quiz_model = (SiteSetting.respond_to?(:gemini_document_quiz_model) && SiteSetting.gemini_document_quiz_model.presence) || model
      ocr_enabled = SiteSetting.respond_to?(:gemini_ocr_enabled) ? SiteSetting.gemini_ocr_enabled : false
      tools_enabled = SiteSetting.respond_to?(:gemini_ai_tools_enabled) ? SiteSetting.gemini_ai_tools_enabled : true
      enabled = ocr_enabled && tools_enabled

      is_authorized = current_user.present? ||
                      request.headers["User-Api-Client-Id"].to_s == "sorumatik_mobile_v4" ||
                      request.headers["User-Api-Key"].present?

      render json: {
        success: true,
        enabled: !!enabled,
        model: model,
        ocr_model: ocr_model,
        document_quiz_model: document_quiz_model,
        api_key: is_authorized ? api_key : ""
      }
    rescue => err
      Rails.logger.error("[Sorumatik AI Config] Error: #{err.message}")
      render json: { success: false, error: err.message }, status: 500
    end

    # POST /sorumatik/save-study
    def save_study
      unless current_user
        return render_json_error(I18n.t("sorumatik_ocr.auth_required"), status: 401)
      end

      title = params[:title].to_s.strip
      prompt = params[:prompt].to_s.strip
      content = params[:content].to_s.strip

      if title.blank? || content.blank?
        return render_json_error("Title and content are required", status: 400)
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
    rescue => err
      Rails.logger.error("[Sorumatik Save Study] Error saving study: #{err.message}")
      render_json_error("Failed to save study: #{err.message}", status: 500)
    end

    # Compatibility import: never regenerate or acknowledge different text.
    def save_solution
      raise Discourse::NotLoggedIn unless current_user
      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::NotFound unless topic
      guardian.ensure_can_see!(topic)
      source = params[:source_post_id].present? ? topic.posts.find(params[:source_post_id]) : topic.first_post
      raise Discourse::InvalidAccess unless source && source.deleted_at.nil? && source.post_type == Post.types[:regular] && source.user_id == current_user.id
      content = params[:content].to_s.strip
      return render_json_error("Content is required", status: 400) if content.blank?
      generation = AnswerGeneration.import!(source, content)
      render json: generation.snapshot.merge(success: generation.state == "completed"),
             status: generation.state == "completed" ? 200 : 202
    rescue GeminiAnswerStream::Failure => e
      return render json: { success: false, error: e.code }, status: 409
    end
  end
end
