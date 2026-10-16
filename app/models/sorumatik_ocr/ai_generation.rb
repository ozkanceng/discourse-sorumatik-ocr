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

    def snapshot
      cleaned_raw = raw.to_s
      {
        protocol: 2,
        generation_id: generation_id,
        topic_id: topic_id,
        source_post_id: source_post_id,
        channel: "/sorumatik/ai-answer/#{source_post_id}",
        sequence: sequence,
        state: state,
        raw: cleaned_raw,
        content_sha256: Digest::SHA256.hexdigest(cleaned_raw),
        post_id: post_id,
        post_number: post&.post_number,
        done: terminal?,
        error: error,
        # Disabling delivery changes the transport, never the generation owner.
        stream_enabled: SiteSetting.sorumatik_ai_generation_streaming_enabled,
      }
    end

    def publish!
      MessageBus.publish(
        "/sorumatik/ai-answer/#{source_post_id}",
        snapshot,
        user_ids: [user_id],
        max_backlog_size: 2,
        max_backlog_age: 10.minutes.to_i,
      )
    rescue StandardError => e
      # Durable status remains readable even if MessageBus is unavailable.
      Rails.logger.warn("sorumatik_ai publish_failed generation_id=#{generation_id} error=#{e.class} message=#{e.message}")
    end
  end
end
