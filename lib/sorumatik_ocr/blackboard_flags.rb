# frozen_string_literal: true

require "digest"

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
      percent = percent_for(key, site_setting)
      return false if percent <= 0
      return true if percent >= 100
      return false unless user&.id

      bucket(key, user.id) < percent
    end

    def percent_for(key, site_setting)
      name = :"sorumatik_blackboard_#{key}_percent"
      return 0 unless site_setting.respond_to?(name)

      site_setting.public_send(name).to_i.clamp(0, 100)
    end

    def bucket(key, user_id)
      Digest::SHA256.hexdigest("#{key}:#{user_id}")[0, 8].to_i(16) % 100
    end

    def beta_user?(user, site_setting)
      return false unless user&.respond_to?(:username) && user.username.present?
      return false unless site_setting.respond_to?(:sorumatik_blackboard_beta_usernames)

      site_setting.sorumatik_blackboard_beta_usernames.to_s.split(/[|,]/).map(&:strip)
        .reject(&:empty?).any? { |name| name.casecmp?(user.username.to_s) }
    end
  end
end
