# frozen_string_literal: true

module SorumatikOcr
  class StudyRoomsController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    before_action :ensure_logged_in, except: [:summary]

    # POST /sorumatik/study-rooms/:id/heartbeat
    def heartbeat
      room_id = params[:id].to_s.strip
      if room_id.blank?
        return render_json_error("Room id is required", status: 400)
      end

      subject = params[:subject].to_s.strip.presence || "Genel Çalışma"
      status = params[:status].to_s.strip.presence || "studying"
      studied_seconds = params[:studied_seconds_today].to_i

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
    rescue => err
      Rails.logger.error("[Sorumatik Study Room Heartbeat] Error: #{err.message}")
      render json: { success: false, error: err.message }, status: 500
    end

    # POST /sorumatik/study-rooms/:id/leave
    def leave
      room_id = params[:id].to_s.strip
      if room_id.present? && current_user
        presence_key = "sorumatik:study_room:#{room_id}:presence"
        users_key = "sorumatik:study_room:#{room_id}:users"
        Discourse.redis.zrem(presence_key, current_user.id.to_s)
        Discourse.redis.hdel(users_key, current_user.id.to_s)
      end

      render json: { success: true }
    rescue => err
      Rails.logger.warn("[Sorumatik Study Room Leave] Notice: #{err.message}")
      render json: { success: true }
    end

    # POST /sorumatik/study-rooms/:id/cheer
    def cheer
      room_id = params[:id].to_s.strip
      emoji = params[:emoji].to_s.strip.presence || "🔥"
      target_user = params[:target_user].to_s.strip.presence

      if room_id.blank?
        return render_json_error("Room id is required", status: 400)
      end

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
    rescue => err
      Rails.logger.error("[Sorumatik Study Room Cheer] Error: #{err.message}")
      render json: { success: false, error: err.message }, status: 500
    end

    # GET /sorumatik/study-rooms/summary
    def summary
      room_ids = params[:room_ids].to_s.split(",").map(&:strip).reject(&:blank?)
      default_ids = %w[101 102 103 104 105 201 202 203 204 301 302 303 401 402 403 501 502 503]
      query_ids = (room_ids.presence || default_ids).uniq

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
    rescue => err
      Rails.logger.error("[Sorumatik Study Room Summary] Error: #{err.message}")
      render json: { success: false, error: err.message }, status: 500
    end
  end
end
