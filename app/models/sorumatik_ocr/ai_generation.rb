# frozen_string_literal: true

require "digest"
require "securerandom"

module SorumatikOcr
  class AiGeneration < ActiveRecord::Base
    self.table_name = "sorumatik_ai_generations"
    belongs_to :source_post, class_name: "::Post"
    belongs_to :post, class_name: "::Post", optional: true
    before_validation { self.generation_id ||= SecureRandom.uuid }
    validates :source_post_id, :topic_id, :user_id, presence: true
    validates :state, inclusion: { in: %w[queued generating persisting completed failed] }

    def terminal?
      %w[completed failed].include?(state)
    end

    def active?
      %w[queued generating persisting].include?(state)
    end

    def snapshot
      cleaned_raw = raw.to_s
      computed_hash = Digest::SHA256.hexdigest(cleaned_raw)
      stored_hash = respond_to?(:content_sha256) ? content_sha256 : nil
      effective_hash = stored_hash.presence || computed_hash

      {
        protocol: 3,
        server_generation: true,
        generation_id: generation_id,
        execution_id: respond_to?(:execution_id) ? execution_id : nil,
        topic_id: topic_id,
        source_post_id: source_post_id,
        source_post_number: source_post&.post_number || 1,
        channel: "/sorumatik/ai-answer/#{source_post_id}",
        topic_channel: topic_id.present? && topic_id > 0 ? "/sorumatik/ai-answer/topic/#{topic_id}" : nil,
        sequence: sequence,
        state: state,
        raw: cleaned_raw,
        content_sha256: effective_hash,
        post_id: post_id,
        post_number: post&.post_number,
        done: terminal?,
        provider_completed: respond_to?(:provider_completed) ? !!provider_completed : false,
        error: error,
        # Disabling delivery changes the transport, never the generation owner.
        stream_enabled: SiteSetting.sorumatik_ai_generation_streaming_enabled &&
          (!SiteSetting.respond_to?(:sorumatik_ai_generation_streaming_percent) || SiteSetting.sorumatik_ai_generation_streaming_percent.to_i >= 100 || (user_id.to_i % 100 < SiteSetting.sorumatik_ai_generation_streaming_percent.to_i)),
      }
    end

    def publish!
      target_topic = (respond_to?(:topic) ? topic : nil) || (source_post&.topic)
      target_topic ||= ::Topic.find_by(id: topic_id) if defined?(::Topic) && topic_id.present?
      effective_topic_id = topic_id.presence || target_topic&.id
      publish_opts = {
        max_backlog_size: 5,
        max_backlog_age: 10.minutes.to_i,
      }

      is_hidden_or_unlisted = (source_post.respond_to?(:hidden?) && source_post.hidden?) ||
                              (target_topic.respond_to?(:visible) && target_topic.visible == false)

      if target_topic.nil? || is_hidden_or_unlisted
        publish_opts[:user_ids] = [user_id].compact
      elsif target_topic.respond_to?(:private_message?) && target_topic.private_message?
        allowed_ids = target_topic.topic_allowed_users.pluck(:user_id) rescue nil
        publish_opts[:user_ids] = (allowed_ids.presence || [user_id]).compact.uniq
      elsif target_topic.respond_to?(:category) && target_topic.category&.read_restricted?
        group_ids = target_topic.category.secure_group_ids rescue nil
        if group_ids.present?
          publish_opts[:group_ids] = group_ids
        else
          publish_opts[:user_ids] = [user_id].compact
        end
      end

      snap = snapshot

      # 1. Post-based channel (mobile and direct post watchers)
      MessageBus.publish(
        "/sorumatik/ai-answer/#{source_post_id}",
        snap,
        publish_opts
      )

      # 2. Topic-based channel (web theme component topic viewers)
      if effective_topic_id.present? && effective_topic_id.to_i > 0
        MessageBus.publish(
          "/sorumatik/ai-answer/topic/#{effective_topic_id}",
          snap,
          publish_opts
        )
      end
    rescue StandardError => e
      # Durable status remains readable even if MessageBus is unavailable.
      Rails.logger.warn("sorumatik_ai publish_failed generation_id=#{generation_id} error=#{e.class} message=#{e.message}")
    end
  end
end
