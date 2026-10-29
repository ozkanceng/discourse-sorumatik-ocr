# frozen_string_literal: true

require "ipaddr"
require "net/http"
require "resolv"
require "uri"

module SorumatikOcr
  module SecurityPolicy
    MOBILE_CLIENT_ID = "sorumatik_mobile_v4"

    MODEL_NAME_REGEX = /\Agemini-[a-z0-9]+(?:[.-][a-z0-9]+)*\z/
    ROOM_ID_REGEX = /\A[a-zA-Z0-9_-]{1,32}\z/
    TTS_VOICE_REGEX = /\A[A-Za-z0-9_-]{1,32}\z/

    BLOCKED_MODEL_TOKENS = %w[
      pro
      argon
      ultra
      imagen
      veo
      banana
      robotics
      computer-use
      deep-research
      lyria
    ].freeze

    DEFAULT_ALLOWED_TEXT_MODELS = %w[
      gemini-2.5-flash
      gemini-2.5-flash-lite
      gemini-2.0-flash
      gemini-2.0-flash-lite
      gemini-3-flash
      gemini-3.1-flash-lite
      gemini-3.5-flash-lite
      gemini-3.6-flash
      gemini-3.7-flash
      gemini-3.8-flash
    ].freeze

    DEFAULT_ALLOWED_OCR_MODELS = %w[
      gemini-2.5-flash-lite
      gemini-2.0-flash-lite
      gemini-3.1-flash-lite
      gemini-3.5-flash-lite
      gemini-2.5-flash
    ].freeze

    DEFAULT_ALLOWED_TTS_MODELS = %w[
      gemini-3.8-flash-lite-tts
      gemini-2.5-flash-tts
      gemini-2.5-flash-preview-tts
      gemini-3.1-flash-tts
      gemini-3.8-flash-tts
    ].freeze

    ALLOWED_MEDIA_MIME_TYPES = %w[
      image/jpeg
      image/jpg
      image/png
      image/webp
      image/gif
      application/pdf
    ].freeze

    ALLOWED_OCR_MIME_TYPES = %w[
      image/jpeg
      image/jpg
      image/png
      image/webp
    ].freeze

    DEFAULT_TRUSTED_HOSTS = %w[
      sorumatik.co
      www.sorumatik.co
      en.sorumatik.co
      blog.sorumatik.co
      cdn.sorumatik.co
    ].freeze

    BLOCKED_IP_RANGES = [
      IPAddr.new("0.0.0.0/8"),
      IPAddr.new("10.0.0.0/8"),
      IPAddr.new("100.64.0.0/10"),
      IPAddr.new("127.0.0.0/8"),
      IPAddr.new("169.254.0.0/16"),
      IPAddr.new("172.16.0.0/12"),
      IPAddr.new("192.0.0.0/24"),
      IPAddr.new("192.168.0.0/16"),
      IPAddr.new("198.18.0.0/15"),
      IPAddr.new("224.0.0.0/4"),
      IPAddr.new("240.0.0.0/4"),
      IPAddr.new("255.255.255.255/32"),
      IPAddr.new("::/128"),
      IPAddr.new("::1/128"),
      IPAddr.new("fc00::/7"),
      IPAddr.new("fe80::/10"),
      IPAddr.new("ff00::/8")
    ].freeze

    SPAM_PHRASE_REGEX = Regexp.union(
      /\boccult\s+society\b/i,
      /\bbonafide\s+member\b/i,
      /\bgreat\s+legion\b/i,
      /\briches\s+and\s+powers?\b/i,
      /\bspiritual\s+solutions?\b/i,
      /\bmoney\s+rituals?\b/i,
      /\billuminati\s+brotherhood\b/i,
      /\blove\s+spell\s+caster\b/i,
      /\bcrypto(?:currency)?\s+recovery\b/i,
      /\bbinary\s+options?\s+recovery\b/i,
      /\bbuy\s+(?:fake|real)\s+passports?\b/i,
      /\bdeneme\s+bonusu\s+veren\s+siteler\b/i,
      /\bkaçak\s+bahis\s+siteleri\b/i,
      /\bslot\s+casino\s+bonus\b/i
    ).freeze

    INTL_PHONE_REGEX = /(?<!\d)\+\d{10,15}(?!\d)/
    PHONE_SPAM_CONTEXT_REGEX = /\b(?:whatsapp|telegram|viber|occult|spell|ritual|illuminati|casino|betting|forex|loan\s+offer|hack(?:er|ing)?)\b/i

    module_function

    def blocked_model_name?(model_name)
      down = model_name.to_s.strip.downcase
      return true if down.empty? || !down.match?(MODEL_NAME_REGEX)

      BLOCKED_MODEL_TOKENS.any? do |token|
        down.include?("-#{token}") || down.include?(".#{token}") || down.start_with?("#{token}-")
      end
    end

    def configured_allowed_models(site_setting)
      return [] unless site_setting && site_setting.respond_to?(:gemini_ai_allowed_models)

      raw = site_setting.gemini_ai_allowed_models.to_s.strip
      return [] if raw.empty?

      raw.split(/[|,\s]+/)
         .map { |entry| entry.strip.downcase }
         .reject { |entry| entry.empty? || blocked_model_name?(entry) }
         .uniq
    end

    def resolve_text_model(requested, site_setting: nil, setting_model: nil, fallback: "gemini-2.5-flash")
      custom = configured_allowed_models(site_setting)
      allowed = custom.empty? ? DEFAULT_ALLOWED_TEXT_MODELS : custom

      req = requested.to_s.strip.downcase
      return req if !req.empty? && !blocked_model_name?(req) && allowed.include?(req)

      cfg = setting_model.to_s.strip.downcase
      return cfg if !cfg.empty? && !blocked_model_name?(cfg)

      fb = fallback.to_s.strip.downcase
      !fb.empty? && !blocked_model_name?(fb) ? fb : "gemini-2.5-flash"
    end

    def resolve_ocr_model(requested, site_setting: nil, fallback: "gemini-2.5-flash-lite")
      custom = configured_allowed_models(site_setting)
      allowed = custom.empty? ? DEFAULT_ALLOWED_OCR_MODELS : (DEFAULT_ALLOWED_OCR_MODELS | custom)

      req = requested.to_s.strip.downcase
      return req if !req.empty? && !blocked_model_name?(req) && allowed.include?(req)

      cfg = (site_setting && site_setting.respond_to?(:gemini_ocr_model) ? site_setting.gemini_ocr_model : nil).to_s.strip.downcase
      return cfg if !cfg.empty? && !blocked_model_name?(cfg)

      fb = fallback.to_s.strip.downcase
      !fb.empty? && !blocked_model_name?(fb) ? fb : "gemini-2.5-flash-lite"
    end

    def resolve_tts_model(requested, site_setting: nil, fallback: "gemini-3.8-flash-lite-tts")
      req = requested.to_s.strip.downcase
      return req if !req.empty? && !blocked_model_name?(req) && DEFAULT_ALLOWED_TTS_MODELS.include?(req)

      cfg = if site_setting
        ((site_setting.respond_to?(:gemini_tts_model) && site_setting.gemini_tts_model) ||
         (site_setting.respond_to?(:blackboard_tts_model) && site_setting.blackboard_tts_model)).to_s.strip.downcase
      else
        ""
      end
      return cfg if !cfg.empty? && !blocked_model_name?(cfg) && cfg.include?("tts")

      fallback
    end

    def active_user?(user)
      return false if user.nil?
      return false if user.respond_to?(:active?) && !user.active?
      return false if user.respond_to?(:suspended?) && user.suspended?
      return false if user.respond_to?(:silenced?) && user.silenced?
      return false if user.respond_to?(:staged) && user.staged == true

      true
    end

    def valid_mobile_client?(request)
      return false unless request

      header_value(request, "User-Api-Client-Id") == MOBILE_CLIENT_ID
    end

    def same_origin_request?(request, current_user: nil, allowed_hosts: nil)
      return false unless request

      method = request.respond_to?(:request_method) ? request.request_method.to_s.upcase : "POST"
      return true if %w[GET HEAD OPTIONS].include?(method)

      hosts = trusted_hosts_for_request(request, allowed_hosts)
      origin = header_value(request, "Origin")

      if !origin.empty?
        return false if origin.casecmp?("null")

        origin_host = extract_uri_host(origin)
        return !origin_host.nil? && hosts.include?(origin_host)
      end

      # Guest mobile calls without a cookie user session cannot carry cookie CSRF authority
      return true if current_user.nil?

      # Authenticated mobile requests via User-Api-Key do not use browser cookies
      api_key = header_value(request, "User-Api-Key")
      return true if !api_key.empty?

      referer = header_value(request, "Referer")
      if !referer.empty?
        referer_host = extract_uri_host(referer)
        return !referer_host.nil? && hosts.include?(referer_host)
      end

      xhr = header_value(request, "X-Requested-With")
      return true if xhr.casecmp?("XMLHttpRequest")

      csrf = header_value(request, "X-CSRF-Token")
      return true if !csrf.empty?

      false
    end

    def private_or_reserved_ip?(ip_str)
      cleaned = ip_str.to_s.strip.sub(/\A\[/, "").sub(/\]\z/, "").sub(/%.+\z/, "")
      return true if cleaned.empty?

      ip = IPAddr.new(cleaned)
      ip = ip.native if ip.respond_to?(:ipv4_mapped?) && ip.ipv4_mapped?
      BLOCKED_IP_RANGES.any? { |range| range.include?(ip) }
    rescue IPAddr::InvalidAddressError, ArgumentError
      true
    end

    def allowed_image_hosts(extra_hosts = nil)
      hosts = DEFAULT_TRUSTED_HOSTS.dup
      Array(extra_hosts).each do |h|
        cleaned = h.to_s.strip.downcase
        hosts << cleaned unless cleaned.empty?
      end

      if defined?(::Discourse)
        if ::Discourse.respond_to?(:current_hostname)
          ch = ::Discourse.current_hostname.to_s.strip.downcase
          hosts << ch unless ch.empty?
        end
        if ::Discourse.respond_to?(:base_url)
          bh = extract_uri_host(::Discourse.base_url)
          hosts << bh if bh
        end
        if ::Discourse.respond_to?(:asset_host) && ::Discourse.asset_host
          ah = extract_uri_host(::Discourse.asset_host.to_s)
          hosts << ah if ah
        end
      end

      if defined?(::GlobalSetting) && ::GlobalSetting.respond_to?(:cdn_url) && ::GlobalSetting.cdn_url
        gh = extract_uri_host(::GlobalSetting.cdn_url.to_s)
        hosts << gh if gh
      end

      if defined?(::SiteSetting) && ::SiteSetting.respond_to?(:s3_cdn_url) && ::SiteSetting.s3_cdn_url
        sh = extract_uri_host(::SiteSetting.s3_cdn_url.to_s)
        hosts << sh if sh
      end

      hosts.uniq
    end

    def safe_image_uri?(raw_url, allowed_hosts: nil, dns_resolver: nil)
      url_str = raw_url.to_s.strip
      return false if url_str.empty?

      uri = URI.parse(url_str)
      return false unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      return false unless %w[http https].include?(uri.scheme)
      return false unless uri.userinfo.nil?

      host = (uri.respond_to?(:hostname) ? uri.hostname : uri.host).to_s.strip.downcase
      return false if host.empty?

      # Direct IP literal check before host allowlist / DNS lookup
      if ip_literal?(host)
        return false if private_or_reserved_ip?(host)
      end

      permitted_hosts = allowed_image_hosts(allowed_hosts)
      return false unless permitted_hosts.include?(host)

      resolver = dns_resolver || Resolv
      addresses = resolver.getaddresses(host)
      return false if addresses.nil? || addresses.empty?
      return false if addresses.any? { |addr| private_or_reserved_ip?(addr) }

      true
    rescue URI::InvalidURIError, Resolv::ResolvError, StandardError
      false
    end

    def fetch_safe_image_bytes(raw_url, max_bytes: 10 * 1024 * 1024, timeout_seconds: 5, allowed_hosts: nil, dns_resolver: nil)
      return nil unless safe_image_uri?(raw_url, allowed_hosts: allowed_hosts, dns_resolver: dns_resolver)

      uri = URI.parse(raw_url.to_s.strip)
      timeout_val = [timeout_seconds.to_f, 1.0].max

      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: timeout_val,
        read_timeout: timeout_val
      ) do |http|
        req = Net::HTTP::Get.new(uri.request_uri)
        http.request(req) do |response|
          # Reject 3xx redirects and non-2xx responses to prevent redirect-based SSRF
          return nil unless response.is_a?(Net::HTTPSuccess)

          content_length = response["Content-Length"]&.to_i
          return nil if content_length && content_length > max_bytes

          buffer = +"".b
          response.read_body do |chunk|
            buffer << chunk
            return nil if buffer.bytesize > max_bytes
          end
          return buffer.empty? ? nil : buffer
        end
      end
    rescue StandardError
      nil
    end

    def spam_or_ineligible_post?(post)
      return true if post.nil?
      return true if post.respond_to?(:deleted_at) && !post.deleted_at.nil?
      return true if post.respond_to?(:hidden?) && post.hidden?
      return true if post.respond_to?(:hidden) && post.hidden == true
      return true if post.respond_to?(:user_deleted) && post.user_deleted == true

      topic = post.respond_to?(:topic) ? post.topic : nil
      return true if topic && topic.respond_to?(:deleted_at) && !topic.deleted_at.nil?
      return true if topic && topic.respond_to?(:visible) && topic.visible == false

      author = post.respond_to?(:user) ? post.user : nil
      return true unless active_user?(author)

      if pending_reviewable_flag?(post)
        return true
      end

      title = topic && topic.respond_to?(:title) ? topic.title.to_s : ""
      raw = post.respond_to?(:raw) ? post.raw.to_s : ""
      combined = "#{title}\n#{raw}"

      return true if combined.match?(SPAM_PHRASE_REGEX)

      if combined.match?(INTL_PHONE_REGEX) && combined.match?(PHONE_SPAM_CONTEXT_REGEX)
        return true
      end

      is_staff = author.respond_to?(:staff?) && author.staff?
      unless is_staff
        ext_count = external_url_count(combined)
        trust_level = author.respond_to?(:trust_level) ? author.trust_level.to_i : 1
        return true if trust_level <= 0 && ext_count >= 3
        return true if ext_count >= 6
      end

      false
    end

    def pending_reviewable_flag?(post)
      return false unless defined?(::Reviewable) && ::Reviewable.respond_to?(:where)
      return false unless post.respond_to?(:id) && post.id

      pending_status = ::Reviewable.respond_to?(:statuses) ? ::Reviewable.statuses[:pending] : 0
      ::Reviewable.where(target_id: post.id, target_type: "Post", status: pending_status).exists?
    rescue StandardError
      false
    end

    def external_url_count(text)
      trusted = allowed_image_hosts
      urls = text.to_s.scan(%r{https?://([a-zA-Z0-9.-]+)}i).flatten
      urls.count do |host|
        h = host.to_s.downcase
        !trusted.include?(h) && !trusted.any? { |th| h.end_with?(".#{th}") }
      end
    end

    def header_value(request, name)
      headers = request.respond_to?(:headers) ? request.headers : nil
      val = headers ? headers[name] : nil
      if val.nil? && request.respond_to?(:env) && request.env
        env_key = "HTTP_#{name.upcase.tr('-', '_')}"
        val = request.env[env_key] || request.env[name]
      end
      val.to_s.strip
    end

    def trusted_hosts_for_request(request, extra_hosts = nil)
      hosts = allowed_image_hosts(extra_hosts)
      if request.respond_to?(:host) && request.host
        rh = request.host.to_s.strip.downcase
        hosts << rh unless rh.empty?
      end
      hosts.uniq
    end

    def extract_uri_host(raw)
      str = raw.to_s.strip
      return nil if str.empty?

      str = "https:#{str}" if str.start_with?("//")
      uri = URI.parse(str)
      host = (uri.respond_to?(:hostname) ? uri.hostname : uri.host).to_s.strip.downcase
      host.empty? ? nil : host
    rescue URI::InvalidURIError
      nil
    end

    def ip_literal?(host)
      IPAddr.new(host)
      true
    rescue IPAddr::InvalidAddressError, ArgumentError
      false
    end
  end
end
