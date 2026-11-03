# frozen_string_literal: true

require "digest"

module SorumatikOcr
  # Percentage rollouts shared by every flag of the plugin.
  #
  # A signed-in user lands in a stable bucket per flag (hash of the flag name
  # and user id), so raising the percentage only adds users. Anonymous users
  # get a flag only at 100%. Usernames in the beta setting get every flag.
  module RolloutFlags
    module_function

    def enabled?(key, user, percent:, beta_usernames: "")
      return true if beta?(user, beta_usernames)
      percent = percent.to_i.clamp(0, 100)
      return false if percent <= 0
      return true if percent >= 100
      return false unless user&.id

      bucket(key, user.id) < percent
    end

    def bucket(key, user_id)
      Digest::SHA256.hexdigest("#{key}:#{user_id}")[0, 8].to_i(16) % 100
    end

    def beta?(user, usernames)
      return false unless user&.respond_to?(:username) && user.username.to_s != ""

      usernames.to_s.split(/[|,]/).map(&:strip).reject(&:empty?).any? { |name| name.casecmp?(user.username.to_s) }
    end

    def setting(site_setting, name, default = nil)
      site_setting.respond_to?(name) ? site_setting.public_send(name) : default
    end
  end

  # Which service generates forum answers: Gemini directly, or the Sorumatik API.
  module AnswerBackend
    module_function

    def api_for?(user, site_setting: SiteSetting)
      return false unless RolloutFlags.setting(site_setting, :sorumatik_answer_backend, "gemini").to_s == "api"
      return false if RolloutFlags.setting(site_setting, :sorumatik_api_service_token, "").to_s.strip.empty?

      RolloutFlags.enabled?("answer_api", user,
                            percent: RolloutFlags.setting(site_setting, :sorumatik_answer_api_percent, 0),
                            beta_usernames: RolloutFlags.setting(site_setting, :sorumatik_api_beta_usernames, ""))
    end

    # Questions asked from the new app (topic created with sorumatik_ai_backend=api) are charged
    # to the asker by the API. The first post is a question; later posts are free follow-ups.
    def charge_for(source)
      first = source.respond_to?(:topic) && source.topic.respond_to?(:first_post) ? source.topic.first_post : nil
      fields = first.respond_to?(:custom_fields) ? first.custom_fields : {}
      return nil unless fields["sorumatik_ai_backend"].to_s == "api"

      is_question = source.respond_to?(:post_number) && source.post_number.to_i == 1
      tier = fields["sorumatik_client_tier"].to_s.strip
      { feature: is_question ? "ask_question" : "follow_up", key: "qa:post:#{source.id}",
        tier: tier.empty? ? nil : tier }
    end

    def base_url(site_setting: SiteSetting)
      url = RolloutFlags.setting(site_setting, :sorumatik_api_base_url, "").to_s.strip
      url.empty? ? "http://172.17.0.1:8000" : url
    end
  end
end

module SorumatikOcr
  # What /sorumatik/ai-config tells the app about api.sorumatik.co (`ai_backend`).
  # A feature is "api" only for users in its rollout bucket; the app always
  # keeps the forum proxy as fallback.
  module AppBackend
    FEATURES = %w[tools ocr tts blackboard qa_client].freeze

    module_function

    def for_user(user, site_setting: SiteSetting)
      enabled = RolloutFlags.setting(site_setting, :sorumatik_app_api_features, "").to_s.split(/[|,]/).map(&:strip)
      percent = RolloutFlags.setting(site_setting, :sorumatik_app_api_percent, 0)
      beta = RolloutFlags.setting(site_setting, :sorumatik_api_beta_usernames, "")
      on = user&.id && RolloutFlags.enabled?("app_api", user, percent: percent, beta_usernames: beta)
      authority = RolloutFlags.setting(site_setting, :sorumatik_app_quota_authority, "device").to_s
      {
        version: 1,
        api_base_url: RolloutFlags.setting(site_setting, :sorumatik_app_api_base_url, "https://api.sorumatik.co").to_s,
        features: FEATURES.to_h { |f| [f, on && enabled.include?(f) ? "api" : "forum"] },
        fallback: "forum",
        quota_authority: on && authority == "server" ? "server" : "device",
        min_app_build: RolloutFlags.setting(site_setting, :sorumatik_api_min_app_build, 0).to_i,
        config_ttl_seconds: 300,
      }
    end

    # Faz 6: builds at or above sorumatik_api_min_app_build must use the API for AI.
    def proxy_closed_for?(request, site_setting: SiteSetting)
      min = RolloutFlags.setting(site_setting, :sorumatik_api_min_app_build, 0).to_i
      return false if min <= 0

      build = request.headers["X-Sorumatik-App-Build"].to_s
      build.match?(/\A\d+\z/) && build.to_i >= min
    end
  end
end
