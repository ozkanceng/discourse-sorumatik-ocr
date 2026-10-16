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
        channel: "/sorumatik/ai-answer/#{source_post_id}",
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
      publish_opts = {
        max_backlog_size: 2,
        max_backlog_age: 10.minutes.to_i,
      }

      if target_topic&.respond_to?(:private_message?) && target_topic.private_message?
        allowed_ids = target_topic.topic_allowed_users.pluck(:user_id) rescue nil
        publish_opts[:user_ids] = (allowed_ids.presence || [user_id])
      elsif target_topic&.respond_to?(:category) && target_topic.category&.read_restricted?
        publish_opts[:group_ids] = target_topic.category.secure_group_ids rescue nil
      end

      MessageBus.publish(
        "/sorumatik/ai-answer/#{source_post_id}",
        snapshot,
        publish_opts
      )
    rescue StandardError => e
      # Durable status remains readable even if MessageBus is unavailable.
      Rails.logger.warn("sorumatik_ai publish_failed generation_id=#{generation_id} error=#{e.class} message=#{e.message}")
    end
  end
end
