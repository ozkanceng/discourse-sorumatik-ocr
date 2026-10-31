# frozen_string_literal: true

require "securerandom"

module SorumatikOcr
  # Caps concurrent Gemini SSE proxy streams across all web processes. Each
  # stream holds a web worker for up to READ_TIMEOUT seconds, so a surge of
  # mobile fallbacks must not be able to occupy every worker of the forum.
  module ProxyCapacity
    KEY = "sorumatik_ai_proxy_streams"
    DEFAULT_LIMIT = 6
    # Longer than the proxy read timeout, so slots of crashed workers expire.
    SLOT_TTL_SECONDS = 200

    module_function

    def limit
      value = SiteSetting.respond_to?(:gemini_ai_proxy_max_concurrent_streams) ? SiteSetting.gemini_ai_proxy_max_concurrent_streams.to_i : 0
      value > 0 ? value : DEFAULT_LIMIT
    end

    def available?(redis: default_redis, now: Time.now.to_f)
      prune(redis, now)
      redis.zcard(KEY).to_i < limit
    rescue StandardError => e
      log_failure(e)
      true
    end

    # Returns a slot id, or nil when the proxy is full. Redis failures fail
    # open with :untracked so the proxy keeps its previous behaviour.
    def acquire(redis: default_redis, now: Time.now.to_f)
      prune(redis, now)
      slot = SecureRandom.hex(8)
      redis.zadd(KEY, now, slot)
      if redis.zcard(KEY).to_i > limit
        redis.zrem(KEY, slot)
        return nil
      end
      slot
    rescue StandardError => e
      log_failure(e)
      :untracked
    end

    def release(slot, redis: default_redis)
      return if slot.nil? || slot == :untracked
      redis.zrem(KEY, slot)
    rescue StandardError => e
      log_failure(e)
    end

    def prune(redis, now)
      redis.zremrangebyscore(KEY, "-inf", now - SLOT_TTL_SECONDS)
    end

    def default_redis
      Discourse.redis
    end

    def log_failure(error)
      Rails.logger.warn("[Sorumatik AI Proxy] capacity_check_failed error=#{error.class}")
    end
  end
end
