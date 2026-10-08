# frozen_string_literal: true

# name: discourse-sorumatik-ocr
# about: Sorumatik için ultra hızlı Google Gemini 2.5 Flash-Lite tabanlı Matematik/Sınav OCR eklentisi.
# version: 1.1.0
# authors: Sorumatik
# url: https://github.com/ozkanceng/discourse-sorumatik-ocr

enabled_site_setting :gemini_ocr_enabled

after_initialize do
  module ::SorumatikOcr
    PLUGIN_NAME = "discourse-sorumatik-ocr"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace SorumatikOcr
    end
  end

  require_relative "app/controllers/sorumatik_ocr/ocr_controller"
  require_relative "app/controllers/sorumatik_ocr/ai_solve_controller"
  require_relative "app/controllers/sorumatik_ocr/ai_config_controller"
  require_relative "app/controllers/sorumatik_ocr/ai_controller"
  require_relative "app/models/sorumatik_ocr/ai_generation"
  require_relative "lib/sorumatik_ocr/gemini_answer_stream"
  require_relative "lib/sorumatik_ocr/answer_generation"
  require_relative "app/controllers/sorumatik_ocr/ai_generations_controller"
  require_relative "app/controllers/sorumatik_ocr/study_rooms_controller"
  require_dependency "jobs/base" unless defined?(::Jobs::Base)
  require_relative "app/jobs/regular/sorumatik_generate_answer"
  require_relative "app/jobs/scheduled/sorumatik_recover_answers"

  begin
    require_dependency "discourse_ai/ai_bot/playground"
    require_relative "lib/sorumatik_ocr/managed_ai_reply"
    DiscourseAi::AiBot::Playground.prepend(SorumatikOcr::ManagedAiReply)
  rescue LoadError, NameError => e
    Rails.logger.warn("sorumatik_ai native_adapter_unavailable error=#{e.class}")
  end

  # Recheck visibility at delivery time, including replay of the bus backlog.
  MessageBus.register_client_message_filter("/sorumatik/ai-answer/") do |message|
    data = message.data
    if data.is_a?(Hash) && (data["protocol"] || data[:protocol]) == 2
      ActiveRecord::Base.connection_pool.with_connection do
        id = data["generation_id"] || data[:generation_id]
        generation = SorumatikOcr::AiGeneration.find_by(generation_id: id)
        source = generation&.source_post
        source && source.deleted_at.nil? && source.user &&
          Guardian.new(source.user).can_see?(source.topic)
      end
    else
      true # Existing protocol-1 publishers retain their own audience rules.
    end
  end

  on(:post_created) do |post, _opts|
    if SorumatikOcr::AnswerGeneration.managed_source?(post)
      begin
        SorumatikOcr::AnswerGeneration.start!(post)
      rescue StandardError => e
        Rails.logger.warn("sorumatik_ai enqueue_failed source_post_id=#{post.id} error=#{e.class}")
      end
    end
  end

  add_to_serializer(:topic_view, :sorumatik_pending_generation) do
    if scope.user
      generation = SorumatikOcr::AiGeneration.where(topic_id: object.topic.id, user_id: scope.user.id)
        .order(created_at: :desc, id: :desc).first
      # An earlier failed answer must not reappear over a newer completed one.
      source = generation&.source_post
      if generation && generation.state != "completed" && source && source.deleted_at.nil? && scope.can_see?(source)
        { generation_id: generation.generation_id, source_post_id: generation.source_post_id }
      end
    end
  end

  # Raw is the shared renderer's source on both topic loads and single-post reads.
  add_to_serializer(:post, :sorumatik_ai_raw, include_condition: -> {
    object.user&.username == SiteSetting.gemini_ai_solve_bot_username
  }) { object.raw }
  add_to_serializer(:post, :sorumatik_generation_id, include_condition: -> {
    object.custom_fields["sorumatik_generation_id"].present?
  }) { object.custom_fields["sorumatik_generation_id"] }

  SorumatikOcr::Engine.routes.draw do
    post "/ocr" => "ocr#extract"
    post "/stream-solve" => "ai_solve#stream"
    post "/ai-solve" => "ai_solve#stream"
    get  "/ai-config" => "ai_config#show"
    post "/ai/generate" => "ai#generate"
    post "/ai/tts" => "ai#tts"
    post "/ai/coach" => "ai#coach"
    post "/ai/plan" => "ai#plan"
    post "/ai/solve" => "ai#solve"
    post "/save-study" => "ai_config#save_study"
    post "/save-solution" => "ai_config#save_solution"
    post "/ai-generations" => "ai_generations#create"
    get "/ai-generations/:id" => "ai_generations#show"
    post "/study-rooms/:id/heartbeat" => "study_rooms#heartbeat"
    post "/study-rooms/:id/leave"     => "study_rooms#leave"
    post "/study-rooms/:id/cheer"     => "study_rooms#cheer"
    get  "/study-rooms/summary"        => "study_rooms#summary"
  end

  Discourse::Application.routes.append do
    mount ::SorumatikOcr::Engine, at: "/sorumatik"
  end

  # Mobilden sorulan konularda web otomasyon botunun (@sorumatik_uzman_bot) ve mükerrer @sorumatik_ai yanıtlarının engellenmesi
  validate(:post, :validate_sorumatik_automation_suppression) do
    suppress_bot = SiteSetting.gemini_ai_suppress_automation_bot_username.presence || "sorumatik_uzman_bot"
    bot_username = SiteSetting.gemini_ai_solve_bot_username.presence || "sorumatik_ai"
    is_bot_user = user.present? && (user.username.to_s.casecmp?(bot_username) || user.username.to_s.casecmp?(suppress_bot))

    # Botlar hiçbir zaman forumda birinci post (yeni konu açılışı) olamaz
    if is_bot_user && (post_number == 1 || is_first_post?)
      Rails.logger.warn("[Sorumatik AI] Blocked bot #{user.username} from opening a new topic")
      errors.add(:base, "Bot kullanıcıları doğrudan konu açamaz.")
      next
    end

    if user.present? && user.username.to_s.casecmp?(suppress_bot)
      if topic.present?
        has_ai_presence = topic.tags.exists?(name: "soru-cozumu") ||
                          topic.custom_fields["ai_solve_handled"].present? ||
                          topic.posts.joins(:user).where(users: { username: bot_username }).exists?
        if has_ai_presence
          Rails.logger.info("[Sorumatik AI] Suppressing automation bot #{suppress_bot} for topic ##{topic_id}")
          errors.add(:base, "Bu konu mobil uygulama çözümü içerdiği için otomasyon botu yanıtı engellendi.")
        end
      end
    end

    # Yapay zeka aracı PM'lerinde (ai_module_handled) Discourse AI botunun mükerrer 2. cevap eklemesini engelle
    if topic.present? && topic.custom_fields["ai_module_handled"] == "true"
      if is_bot_user
        if topic.posts.where(user_id: user.id).where.not(id: id).exists?
          Rails.logger.info("[Sorumatik AI] Suppressing duplicate bot reply on study PM ##{topic.id}")
          errors.add(:base, "Bu çalışma için zaten bir yanıt mevcut.")
        end
      end
    end

    # Genel Mükerrer Bot Cevabı Koruması:
    # Herhangi bir kullanıcı mesajından sonra birden fazla bot cevabı (discourse-ai + discourse-sorumatik-ocr) üretilmesini engelle
    if is_bot_user && topic.present? && topic.custom_fields["ai_module_handled"] != "true"
      last_user_post = topic.posts.where.not(user_id: user.id).order(:post_number).last
      if last_user_post.present?
        existing_bot_replies = topic.posts.where(user_id: user.id).where("post_number > ?", last_user_post.post_number)
        existing_bot_replies = existing_bot_replies.where.not(id: id) if id.present?
        if existing_bot_replies.exists?
          Rails.logger.info("[Sorumatik AI] Suppressing duplicate bot response (#{user.username}) on topic ##{topic.id} after post ##{last_user_post.post_number}")
          errors.add(:base, "Bu soru/mesaj için zaten bir bot yanıtı mevcut.")
        end
      end
    end
  end

  on(:before_create_post) do |post|
    suppress_bot = SiteSetting.gemini_ai_suppress_automation_bot_username.presence || "sorumatik_uzman_bot"
    bot_username = SiteSetting.gemini_ai_solve_bot_username.presence || "sorumatik_ai"
    t = post.topic
    is_bot = post.user.present? && (post.user.username.to_s.casecmp?(bot_username) || post.user.username.to_s.casecmp?(suppress_bot))

    # Botlar yeni konu açamaz
    if is_bot && (post.is_first_post? || (t.present? && t.posts_count.to_i == 0))
      Rails.logger.warn("[Sorumatik AI] Halting bot #{post.user.username} from creating topic ##{t&.id}")
      throw(:abort)
    end

    if post.user.present? && post.user.username.to_s.casecmp?(suppress_bot)
      if t.present?
        has_ai_presence = t.tags.exists?(name: "soru-cozumu") ||
                          t.custom_fields["ai_solve_handled"].present? ||
                          t.posts.joins(:user).where(users: { username: bot_username }).exists?
        if has_ai_presence
          Rails.logger.info("[Sorumatik AI] Halting automation bot #{suppress_bot} post creation on topic ##{t.id}")
          throw(:abort)
        end
      end
    end

    # Yapay zeka aracı PM'lerinde botun ikinci kez tetiklenmesini engelle
    if t.present? && t.custom_fields["ai_module_handled"] == "true"
      if is_bot
        existing_bot_posts = t.posts.where(user_id: post.user_id).count
        if existing_bot_posts >= 1 && post.id.nil?
          Rails.logger.info("[Sorumatik AI] Halting duplicate bot reply (#{post.user.username}) on study PM ##{t.id}")
          throw(:abort)
        end
      end
    end

    # Genel Mükerrer Bot Cevabı Koruması:
    # Herhangi bir kullanıcı mesajından sonra birden fazla bot cevabı (discourse-ai + discourse-sorumatik-ocr) üretilmesini engelle
    if is_bot && t.present? && t.custom_fields["ai_module_handled"] != "true"
      last_user_post = t.posts.where.not(user_id: post.user_id).order(:post_number).last
      if last_user_post.present?
        existing_bot_replies = t.posts.where(user_id: post.user_id).where("post_number > ?", last_user_post.post_number)
        if existing_bot_replies.exists?
          Rails.logger.info("[Sorumatik AI] Halting duplicate bot response (#{post.user.username}) on topic ##{t.id} after post ##{last_user_post.post_number}")
          throw(:abort)
        end
      end
    end
  end
end
