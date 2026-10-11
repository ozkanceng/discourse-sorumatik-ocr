# frozen_string_literal: true

module ::Jobs
  class SorumatikFallbackAnswer < ::Jobs::Base
    sidekiq_options retry: false

    def execute(args)
      return unless SiteSetting.gemini_ai_solve_enabled

      post = Post.find_by(id: args[:post_id])
      return unless post && post.deleted_at.nil? && post.post_type == Post.types[:regular]

      topic = post.topic
      return unless topic && topic.deleted_at.nil?

      bot_username = SiteSetting.gemini_ai_solve_bot_username.presence || "sorumatik_ai"
      bot = User.find_by_username(bot_username)
      return unless bot
      return if post.user_id == bot.id

      # If topic already has an answer from the bot after this post, don't generate again
      has_bot_answer = topic.posts.where(user_id: bot.id).where("post_number > ?", post.post_number).exists?
      return if has_bot_answer

      # If there is already an active or completed generation for this source post, do not duplicate
      generation = SorumatikOcr::AiGeneration.find_by(source_post_id: post.id)
      return if generation && %w[completed persisting generating].include?(generation.state)

      Rails.logger.info("[Sorumatik AI] Fallback triggered for orphaned source post ##{post.id} (topic ##{topic.id})")
      SorumatikOcr::AnswerGeneration.start!(post, fallback: true)
    rescue StandardError => e
      Rails.logger.warn("[Sorumatik AI] Fallback execution failed for post ##{args[:post_id]}: #{e.class} - #{e.message}")
    end
  end
end
