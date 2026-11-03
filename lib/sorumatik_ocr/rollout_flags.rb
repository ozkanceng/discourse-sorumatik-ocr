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

    def base_url(site_setting: SiteSetting)
      url = RolloutFlags.setting(site_setting, :sorumatik_api_base_url, "").to_s.strip
      url.empty? ? "http://172.17.0.1:8000" : url
    end
  end
end
