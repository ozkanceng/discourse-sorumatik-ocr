# frozen_string_literal: true

module SorumatikOcr
  class StudyRoomsController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    before_action :ensure_logged_in, except: [:summary]

    ALLOWED_STATUSES = %w[studying break idle].freeze
    MAX_SUMMARY_ROOMS = 30
    MAX_SUBJECT_CHARS = 80
    MAX_EMOJI_CHARS = 16
    MAX_TARGET_USER_CHARS = 60

    # POST /sorumatik/study-rooms/:id/heartbeat
    def heartbeat
      return render_json_error("Forbidden", status: 403) unless SecurityPolicy.active_user?(current_user)
      return render_json_error("Forbidden", status: 403) unless SecurityPolicy.same_origin_request?(request, current_user: current_user)

      room_id = valid_room_id(params[:id])
      if room_id.nil?
        return render_json_error("Invalid room id", status: 400)
      end

      RateLimiter.new(current_user, "sorumatik_study_heartbeat", 30, 1.minute).performed!

      subject = (params[:subject].to_s.strip.presence || "Genel Çalışma")[0, MAX_SUBJECT_CHARS]
      raw_status = params[:status].to_s.strip.downcase
      status = ALLOWED_STATUSES.include?(raw_status) ? raw_status : "studying"
      studied_seconds = params[:studied_seconds_today].to_i.clamp(0, 86_400)

      now = Time.now.to_i
      presence_key = "sorumatik:study_room:#{room_id}:presence"
      users_key = "sorumatik:study_room:#{room_id}:users"
      cheers_key = "sorumatik:study_room:#{room_id}:cheers"

      # 1. Clean stale users (older than 45 seconds)
      expired_ids = Discourse.redis.zrangebyscore(presence_key, "-inf", now - 45)
      if expired_ids.present?
        Discourse.redis.zremrangebyscore(presence_key, "-inf", now - 45)
        Discourse.redis.hdel(users_key, expired_ids)
      end

      # 2. Add / update active user in Redis
      avatar = if current_user.avatar_template.present?
        if current_user.avatar_template.start_with?("http://", "https://")
          current_user.avatar_template.sub("{size}", "120")
        else
          "#{Discourse.base_url}#{current_user.avatar_template.sub('{size}', '120')}"
        end
      else
        nil
      end

      user_payload = {
        user_id: current_user.id,
        username: current_user.username,
        name: current_user.name.presence || current_user.username,
        avatar_url: avatar,
        avatar_template: current_user.avatar_template,
        role: "member",
        subject: subject,
        status: status,
        studied_seconds_today: studied_seconds,
        is_self: false,
        last_active_at: Time.now.utc.iso8601
      }

      Discourse.redis.zadd(presence_key, now, current_user.id.to_s)
      Discourse.redis.hset(users_key, current_user.id.to_s, user_payload.to_json)
      Discourse.redis.expire(presence_key, 3600)
      Discourse.redis.expire(users_key, 3600)

      # 3. Retrieve all currently active members
      active_ids = Discourse.redis.zrangebyscore(presence_key, now - 45, "+inf")
      members = []
      if active_ids.present?
        raw_list = Discourse.redis.hmget(users_key, active_ids)
        members = raw_list.compact.map do |raw|
          parsed = JSON.parse(raw) rescue nil
          if parsed
            parsed["is_self"] = (parsed["user_id"] == current_user.id)
            parsed
          end
        end.compact
      end

      # Sort members so self is first, then other users by username
      members.sort_by! { |m| [m["is_self"] ? 0 : 1, m["username"].to_s.downcase] }

      # 4. Retrieve recent cheers (last 30 seconds)
      raw_cheers = Discourse.redis.lrange(cheers_key, 0, 15)
      recent_cheers = (raw_cheers || []).map { |c| JSON.parse(c) rescue nil }.compact.select do |c|
        c["created_at"].to_i > (now - 30)
      end

      render json: {
        success: true,
        room_id: room_id,
        member_count: members.size,
        members: members,
        recent_cheers: recent_cheers
      }
    rescue RateLimiter::LimitExceeded
      render json: { success: false, error: "Rate limit exceeded" }, status: 429
    rescue => err
      Rails.logger.error("[Sorumatik Study Room Heartbeat] Error: #{err.class}: #{err.message}")
      render json: { success: false, error: "Study room service unavailable" }, status: 500
    end

    # POST /sorumatik/study-rooms/:id/leave
    def leave
      return render_json_error("Forbidden", status: 403) unless SecurityPolicy.same_origin_request?(request, current_user: current_user)

      room_id = valid_room_id(params[:id])
      if room_id && current_user
        presence_key = "sorumatik:study_room:#{room_id}:presence"
        users_key = "sorumatik:study_room:#{room_id}:users"
        Discourse.redis.zrem(presence_key, current_user.id.to_s)
        Discourse.redis.hdel(users_key, current_user.id.to_s)
      end

      render json: { success: true }
    rescue => err
      Rails.logger.warn("[Sorumatik Study Room Leave] Notice: #{err.class}: #{err.message}")
      render json: { success: true }
    end

    # POST /sorumatik/study-rooms/:id/cheer
    def cheer
      return render_json_error("Forbidden", status: 403) unless SecurityPolicy.active_user?(current_user)
      return render_json_error("Forbidden", status: 403) unless SecurityPolicy.same_origin_request?(request, current_user: current_user)

      room_id = valid_room_id(params[:id])
      if room_id.nil?
        return render_json_error("Invalid room id", status: 400)
      end

      RateLimiter.new(current_user, "sorumatik_study_cheer", 15, 1.minute).performed!

      emoji = (params[:emoji].to_s.strip.presence || "🔥")[0, MAX_EMOJI_CHARS]
      target_user = params[:target_user].to_s.strip.presence&.[](0, MAX_TARGET_USER_CHARS)

      now = Time.now.to_i
      cheers_key = "sorumatik:study_room:#{room_id}:cheers"
      cheer_item = {
        id: "#{now}_#{current_user.id}_#{rand(1000..9999)}",
        sender: current_user.username,
        emoji: emoji,
        target_user: target_user,
        created_at: now
      }

      Discourse.redis.lpush(cheers_key, cheer_item.to_json)
      Discourse.redis.ltrim(cheers_key, 0, 25)
      Discourse.redis.expire(cheers_key, 300)

      render json: { success: true, cheer: cheer_item }
    rescue RateLimiter::LimitExceeded
      render json: { success: false, error: "Rate limit exceeded" }, status: 429
    rescue => err
      Rails.logger.error("[Sorumatik Study Room Cheer] Error: #{err.class}: #{err.message}")
      render json: { success: false, error: "Cheer service unavailable" }, status: 500
    end

    # GET /sorumatik/study-rooms/summary
    def summary
      if current_user
        RateLimiter.new(current_user, "sorumatik_study_summary", 60, 1.minute).performed!
      elsif request.remote_ip.present?
        RateLimiter.new(nil, "sorumatik_study_summary_#{request.remote_ip}", 60, 1.minute, global: true).performed!
      end

      raw_ids = params[:room_ids].to_s.split(",").first(MAX_SUMMARY_ROOMS).map { |id| valid_room_id(id) }.compact
      default_ids = %w[101 102 103 104 105 201 202 203 204 301 302 303 401 402 403 501 502 503]
      query_ids = (raw_ids.presence || default_ids).uniq.first(MAX_SUMMARY_ROOMS)

      now = Time.now.to_i
      counts = {}
      total_active = 0

      query_ids.each do |rid|
        presence_key = "sorumatik:study_room:#{rid}:presence"
        count = Discourse.redis.zcount(presence_key, now - 45, "+inf").to_i
        counts[rid] = count
        total_active += count
      end

      render json: {
        success: true,
        counts: counts,
        total_active: total_active
      }
    rescue RateLimiter::LimitExceeded
      render json: { success: false, error: "Rate limit exceeded" }, status: 429
    rescue => err
      Rails.logger.error("[Sorumatik Study Room Summary] Error: #{err.class}: #{err.message}")
      render json: { success: false, error: "Summary unavailable" }, status: 500
    end

    private

    def valid_room_id(raw_id)
      rid = raw_id.to_s.strip
      rid.match?(SecurityPolicy::ROOM_ID_REGEX) ? rid : nil
    end
  end
end
