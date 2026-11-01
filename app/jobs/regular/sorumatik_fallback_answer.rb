# frozen_string_literal: true

module ::Jobs
  class SorumatikFallbackAnswer < ::Jobs::Base
    sidekiq_options retry: false

    def execute(args)
      return unless SiteSetting.gemini_ai_solve_enabled

      post = Post.find_by(id: args[:post_id])
      return unless post && post.deleted_at.nil? && post.post_type == Post.types[:regular]
      return if SorumatikOcr::SecurityPolicy.spam_or_ineligible_post?(post)

      topic = post.topic
      return unless topic && topic.deleted_at.nil?

      bot_username = SiteSetting.gemini_ai_solve_bot_username.presence || "sorumatik_ai"
      bot = User.find_by_username(bot_username)
      return unless bot
      return if post.user_id == bot.id

      # If the bot already answered this post, don't generate again. Follow-ups
      # are matched by reply target so an answer to another message doesn't count.
      replies = topic.posts.where(user_id: bot.id).where("post_number > ?", post.post_number)
      replies = replies.where(reply_to_post_number: post.post_number == 1 ? [nil, 1] : post.post_number)
      return if replies.exists?

      # If there is already an active, completed, or non-retryably failed generation for this source post, do not duplicate
      generation = SorumatikOcr::AiGeneration.find_by(source_post_id: post.id)
      return if generation && %w[completed persisting generating].include?(generation.state)
      if generation && generation.state == "failed"
        retryable = generation.error&.dig("retryable")
        retryable = generation.error&.dig(:retryable) if retryable.nil?
        err_code = (generation.error&.dig("code") || generation.error&.dig(:code)).to_s
        return if retryable == false && !%w[worker_interrupted persistence_failed].include?(err_code)
      end

      Rails.logger.info("[Sorumatik AI] Fallback triggered for orphaned source post ##{post.id} (topic ##{topic.id})")
      SorumatikOcr::AnswerGeneration.start!(post, fallback: true)
    rescue StandardError => e
      Rails.logger.warn("[Sorumatik AI] Fallback execution failed for post ##{args[:post_id]}: #{e.class} - #{e.message}")
    end
  end
end
