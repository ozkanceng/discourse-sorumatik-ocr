# frozen_string_literal: true

require_relative "rollout_flags"

module SorumatikOcr
  # Kara Tahta v5 feature flags for /sorumatik/ai-config (`blackboard_flags`).
  #
  # Each flag has a rollout percentage setting. A signed-in user lands in a
  # stable bucket per flag (hash of flag name and user id), so the same user
  # keeps the same answer between requests and raising the percentage only
  # adds users. Anonymous requests get a flag only at 100%. Usernames in
  # `sorumatik_blackboard_beta_usernames` get every flag (QA accounts).
  module BlackboardFlags
    KEYS = %w[engine_v5 generation_v5 segment_tts export_v2 verify_answers server_quota].freeze

    module_function

    def for_user(user, site_setting: SiteSetting)
      beta = beta_user?(user, site_setting)
      KEYS.each_with_object({}) do |key, flags|
        flags[key] = beta || enabled?(key, user, site_setting)
      end
    end

    def enabled?(key, user, site_setting)
      RolloutFlags.enabled?(key, user, percent: percent_for(key, site_setting))
    end

    def percent_for(key, site_setting)
      name = :"sorumatik_blackboard_#{key}_percent"
      return 0 unless site_setting.respond_to?(name)

      site_setting.public_send(name).to_i.clamp(0, 100)
    end

    def bucket(key, user_id)
      RolloutFlags.bucket(key, user_id)
    end

    def beta_user?(user, site_setting)
      return false unless site_setting.respond_to?(:sorumatik_blackboard_beta_usernames)

      RolloutFlags.beta?(user, site_setting.sorumatik_blackboard_beta_usernames)
    end
  end
end
