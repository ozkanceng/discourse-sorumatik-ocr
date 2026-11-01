# frozen_string_literal: true

# name: discourse-sorumatik-ocr
# about: Sorumatik için ultra hızlı Google Gemini 3.1 Flash-Lite ve 3.7 Flash tabanlı Matematik/Sınav OCR ve Yapay Zeka Çözücü eklentisi.
# version: 1.3.0
# authors: Sorumatik
# url: https://github.com/ozkanceng/discourse-sorumatik-ocr

enabled_site_setting :gemini_ocr_enabled

after_initialize do
  module ::SorumatikOcr
    PLUGIN_NAME = "discourse-sorumatik-ocr"

    def self.resolve_api_key
      key = (SiteSetting.respond_to?(:sorumatik_ocr_api_key) && SiteSetting.sorumatik_ocr_api_key.presence) ||
            (SiteSetting.respond_to?(:gemini_ocr_api_key) && SiteSetting.gemini_ocr_api_key.presence) ||
            (SiteSetting.respond_to?(:blackboard_gemini_api_key) && SiteSetting.blackboard_gemini_api_key.presence) ||
            ENV["GEMINI_API_KEY"] ||
            ENV["DISCOURSE_GEMINI_OCR_API_KEY"]
      key.to_s.strip
    end

    # Key handed to signed-in mobile apps for on-device answers (protocol 4).
    # It never falls back to the server key: a key the server can use is not
    # restricted to the app packages, so it must not ship to devices.
    def self.resolve_mobile_api_key
      key = SiteSetting.respond_to?(:sorumatik_mobile_gemini_api_key) && SiteSetting.sorumatik_mobile_gemini_api_key.presence
      key.to_s.strip
    end

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace SorumatikOcr
    end
  end

  # Permit only the ownership fields, never arbitrary post custom fields.
  %w[client_edge_solve mobile_answer_protocol mobile_source is_mobile].each do |name|
    Post.plugin_permitted_create_params[name] = { type: :string, plugin: self }
  end

  # Keep comfortable headroom for authenticated mobile User-Api-Key polling/sync
  # (mobile live streaming polls /message-bus/*/poll every ~80ms chunk = ~300 reqs per stream)
  # without disabling Discourse anti-spam topic/post creation rate limits.
  if defined?(::GlobalSetting)
    GlobalSetting.define_singleton_method(:max_user_api_reqs_per_minute) { 2_500 }
    GlobalSetting.define_singleton_method(:max_user_api_reqs_per_day) { 100_000 }
  end

  # Heal legacy v1.2.3 zeroed/10k anti-spam settings if persisted in DB,
  # while respecting any custom values explicitly tuned by the administrator.
  begin
    SiteSetting.rate_limit_create_topic = 5 if SiteSetting.respond_to?(:rate_limit_create_topic=) && SiteSetting.rate_limit_create_topic.to_i <= 0
    SiteSetting.rate_limit_create_post = 3 if SiteSetting.respond_to?(:rate_limit_create_post=) && SiteSetting.rate_limit_create_post.to_i <= 0
    SiteSetting.rate_limit_new_user_create_post = 10 if SiteSetting.respond_to?(:rate_limit_new_user_create_post=) && SiteSetting.rate_limit_new_user_create_post.to_i <= 0
    SiteSetting.gemini_ai_solve_rate_limit_per_minute = 15 if SiteSetting.respond_to?(:gemini_ai_solve_rate_limit_per_minute=) && SiteSetting.gemini_ai_solve_rate_limit_per_minute.to_i >= 10_000
    SiteSetting.max_topics_in_first_day = 30 if SiteSetting.respond_to?(:max_topics_in_first_day=) && SiteSetting.max_topics_in_first_day.to_i >= 10_000
    SiteSetting.max_replies_in_first_day = 50 if SiteSetting.respond_to?(:max_replies_in_first_day=) && SiteSetting.max_replies_in_first_day.to_i >= 10_000
    SiteSetting.max_topics_per_day = 100 if SiteSetting.respond_to?(:max_topics_per_day=) && SiteSetting.max_topics_per_day.to_i >= 10_000
  rescue => e
    Rails.logger.warn("[Sorumatik OCR] Failed restoring safe rate limits: #{e.message}")
  end

  begin
    require "digest"
    require_dependency "auth/default_current_user_provider"
    module ::SorumatikOcr::CurrentUserProviderBypass
      def user_api_key_limiter_60_secs
        raw_key = (@env && (@env["HTTP_USER_API_KEY"] || @env["USER_API_KEY"])).to_s
        key_hash = Digest::SHA256.hexdigest(raw_key)[0, 16]
        is_bus = @env && @env["PATH_INFO"].to_s.start_with?("/message-bus/")
        limit = is_bus ? 10_000 : 2_500
        @user_api_key_limiter_60_secs ||= RateLimiter.new(nil, "sorumatik_uapi_#{is_bus ? 'bus' : 'api'}_min_#{key_hash}", limit, 1.minute)
      end

      def user_api_key_limiter_1_day
        raw_key = (@env && (@env["HTTP_USER_API_KEY"] || @env["USER_API_KEY"])).to_s
        key_hash = Digest::SHA256.hexdigest(raw_key)[0, 16]
        is_bus = @env && @env["PATH_INFO"].to_s.start_with?("/message-bus/")
        limit = is_bus ? 500_000 : 100_000
        @user_api_key_limiter_1_day ||= RateLimiter.new(nil, "sorumatik_uapi_#{is_bus ? 'bus' : 'api'}_day_#{key_hash}", limit, 1.day)
      end
    end
    Auth::DefaultCurrentUserProvider.prepend(SorumatikOcr::CurrentUserProviderBypass)
  rescue LoadError, NameError => e
    Rails.logger.warn("[Sorumatik OCR] Failed to prepend CurrentUserProviderBypass: #{e.message}")
  end

  module ::SorumatikOcr::MobileSourceFields
    def setup_post
      super
      proto = @opts[:mobile_answer_protocol].to_i
      if proto >= 2 || @opts[:client_edge_solve].to_s == "true"
        @post.custom_fields["client_edge_solve"] = @opts[:client_edge_solve].to_s
        @post.custom_fields["mobile_answer_protocol"] = proto > 0 ? proto.to_s : "2"
      end
      if @opts[:mobile_source].to_s == "true"
        @post.custom_fields["mobile_source"] = "true"
      end
    end
  end
  PostCreator.prepend(SorumatikOcr::MobileSourceFields)

  require_relative "lib/sorumatik_ocr/security_policy"
  require_relative "lib/sorumatik_ocr/proxy_capacity"
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
  require_relative "app/jobs/regular/sorumatik_fallback_answer"
  require_relative "app/jobs/scheduled/sorumatik_recover_answers"

  begin
    require_dependency "discourse_ai/ai_bot/playground"
    require_relative "lib/sorumatik_ocr/managed_ai_reply"
    DiscourseAi::AiBot::Playground.prepend(SorumatikOcr::ManagedAiReply)
  rescue LoadError, NameError => e
    Rails.logger.warn("sorumatik_ai native_adapter_unavailable error=#{e.class}")
  end

  # MessageBus channels for AI answer streaming: audience ACLs (user_ids / group_ids)
  # are strictly constrained at publish time in SorumatikOcr::AiGeneration#publish!,
  # avoiding JSON string/Hash mismatch or DB pool contention on the 80ms stream hot path.
  MessageBus.register_client_message_filter("/sorumatik/ai-answer/") do |_message|
    true
  end

  on(:post_created) do |post, _opts|
    next if SorumatikOcr::SecurityPolicy.spam_or_ineligible_post?(post)

    proto = post.custom_fields["mobile_answer_protocol"].to_i
    proto = _opts[:mobile_answer_protocol].to_i if proto == 0 && _opts.is_a?(Hash)

    # Protokol 4: cevabı cihaz üretip kaydeder. Cihaz hiç sahiplenmezse yedek
    # iş, sinyali kesilirse kurtarma işi sunucu üretimini başlatır.
    if proto >= SorumatikOcr::AnswerGeneration::CLIENT_GENERATION_PROTOCOL && post.custom_fields["client_edge_solve"] == "true"
      Jobs.enqueue_in(45.seconds, :sorumatik_fallback_answer, post_id: post.id)
      next
    end

    # Eski Protokol 2 cihaz üstü istemci akışı (yedek 95 saniye fallback):
    if proto == 2 && post.custom_fields["client_edge_solve"] == "true"
      if post.is_first_post?
        Jobs.enqueue_in(95.seconds, :sorumatik_fallback_answer, post_id: post.id)
      end
      next
    end

    # Protokol 3 (ve web akışı):
    # Sunucu üretimi doğrudan ve anında Sidekiq kuyruğuna alınır. 95 saniye beklenmez!
    next unless SorumatikOcr::AnswerGeneration.managed_source?(post)

    begin
      SorumatikOcr::AnswerGeneration.start!(post)
    rescue StandardError => e
      Rails.logger.warn("sorumatik_ai enqueue_failed source_post_id=#{post.id} error=#{e.class}")
    end
  end

  add_to_serializer(:topic_view, :sorumatik_pending_generation) do
    generation = SorumatikOcr::AiGeneration.where(topic_id: object.topic.id)
      .order(created_at: :desc, id: :desc).first
    source = generation&.source_post
    if generation && generation.state != "completed" && source && source.deleted_at.nil? && scope.can_see?(source)
      { generation_id: generation.generation_id, source_post_id: generation.source_post_id }
    end
  end

  add_to_serializer(:post, :client_edge_solve) do
    SorumatikOcr::AnswerGeneration.client_owned_source?(object)
  end
  add_to_serializer(:post, :mobile_answer_protocol) do
    object.custom_fields["mobile_answer_protocol"].to_i
  end

  # Raw is the shared renderer's source on both topic loads and single-post reads.
  add_to_serializer(:post, :sorumatik_ai_raw, include_condition: -> {
    bot_username = SiteSetting.gemini_ai_solve_bot_username.presence || "sorumatik_ai"
    object.user&.username.to_s.casecmp?(bot_username) || object.custom_fields["sorumatik_generation_id"].present?
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
    get  "/ai-generations/active" => "ai_generations#active"
    post "/ai-generations" => "ai_generations#create"
    post "/ai-generations/claim" => "ai_generations#claim"
    get  "/ai-generations/by-source/:source_post_id" => "ai_generations#by_source"
    get  "/ai-generations/by-topic/:topic_id" => "ai_generations#by_topic"
    get  "/ai-generations/:id" => "ai_generations#show"
    post "/study-rooms/:id/heartbeat" => "study_rooms#heartbeat"
    post "/study-rooms/:id/leave"     => "study_rooms#leave"
    post "/study-rooms/:id/cheer"     => "study_rooms#cheer"
    get  "/study-rooms/summary"        => "study_rooms#summary"
  end

  Discourse::Application.routes.append do
    mount ::SorumatikOcr::Engine, at: "/sorumatik"
  end

  # Bot kuralları ve mükerrer bot cevabı engelleme
  validate(:post, :validate_sorumatik_bot_reply) do
    bot_username = SiteSetting.gemini_ai_solve_bot_username.presence || "sorumatik_ai"
    raw_suppress = (SiteSetting.gemini_ai_suppress_automation_bot_username.presence || "sorumatik_uzman_bot").to_s
    suppress_bots = raw_suppress.split(/[|,]/).map(&:strip).reject(&:empty?)
    is_suppress_target = user.present? && !user.username.to_s.casecmp?(bot_username) &&
                         (suppress_bots.any? { |sb| user.username.to_s.casecmp?(sb) } || user.username.to_s.casecmp?("sorumatik_uzman_bot"))
    is_bot_user = user.present? && (user.username.to_s.casecmp?(bot_username) || is_suppress_target)

    # Botlar hiçbir zaman forumda birinci post (yeni konu açılışı) olamaz
    if is_bot_user && (post_number == 1 || is_first_post?)
      Rails.logger.warn("[Sorumatik AI] Blocked bot #{user.username} from opening a new topic")
      errors.add(:base, "Bot kullanıcıları doğrudan konu açamaz.")
      next
    end

    if is_suppress_target
      if topic.present?
        has_ai_presence = SorumatikOcr::AnswerGeneration.question_topic?(topic) ||
                          topic.custom_fields["ai_solve_handled"].present? ||
                          topic.posts.joins(:user).where(users: { username: bot_username }).exists?
        if has_ai_presence
          Rails.logger.info("[Sorumatik AI] Suppressing automation bot #{user.username} for topic ##{topic_id}")
          errors.add(:base, "Bu konu mobil uygulama çözümü içerdiği için otomasyon botu yanıtı engellendi.")
        end
      end
    end

    # Yapay zeka aracı PM'lerinde (ai_module_handled) mükerrer 2. cevap eklemesini engelle
    if topic.present? && topic.custom_fields["ai_module_handled"] == "true"
      if is_bot_user
        if topic.posts.where(user_id: user.id).where.not(id: id).exists?
          Rails.logger.info("[Sorumatik AI] Suppressing duplicate bot reply on study PM ##{topic.id}")
          errors.add(:base, "Bu çalışma için zaten bir yanıt mevcut.")
        end
      end
    end

    # Genel Mükerrer Bot Cevabı Koruması:
    # Herhangi bir kullanıcı mesajından sonra birden fazla bot cevabı üretilmesini engelle
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
    bot_username = SiteSetting.gemini_ai_solve_bot_username.presence || "sorumatik_ai"
    raw_suppress = (SiteSetting.gemini_ai_suppress_automation_bot_username.presence || "sorumatik_uzman_bot").to_s
    suppress_bots = raw_suppress.split(/[|,]/).map(&:strip).reject(&:empty?)
    t = post.topic
    is_suppress_target = post.user.present? && !post.user.username.to_s.casecmp?(bot_username) &&
                         (suppress_bots.any? { |sb| post.user.username.to_s.casecmp?(sb) } || post.user.username.to_s.casecmp?("sorumatik_uzman_bot"))
    is_bot = post.user.present? && (post.user.username.to_s.casecmp?(bot_username) || is_suppress_target)

    # Botlar yeni konu açamaz
    if is_bot && (post.is_first_post? || (t.present? && t.posts_count.to_i == 0))
      Rails.logger.warn("[Sorumatik AI] Halting bot #{post.user.username} from creating topic ##{t&.id}")
      throw(:abort)
    end

    if is_suppress_target
      if t.present?
        has_ai_presence = SorumatikOcr::AnswerGeneration.question_topic?(t) ||
                          t.custom_fields["ai_solve_handled"].present? ||
                          t.posts.joins(:user).where(users: { username: bot_username }).exists?
        if has_ai_presence
          Rails.logger.info("[Sorumatik AI] Halting automation bot #{post.user.username} post creation on topic ##{t.id}")
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
    # Herhangi bir kullanıcı mesajından sonra birden fazla bot cevabı üretilmesini engelle
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
