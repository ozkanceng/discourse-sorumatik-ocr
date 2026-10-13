# frozen_string_literal: true

module ::Jobs
  class SorumatikRecoverAnswers < ::Jobs::Scheduled
    every 1.minute

    def execute(_args)
      # 1. Recover stalled AiGeneration records
      SorumatikOcr::AiGeneration.where(state: %w[queued persisting generating]).where("updated_at < ?", 2.minutes.ago).find_each do |generation|
        if generation.state == "generating"
          generation.with_lock do
            next unless generation.state == "generating" && generation.updated_at < 2.minutes.ago
            generation.update!(state: "failed", sequence: generation.sequence + 1,
                               error: { code: "worker_interrupted", message: "Yanıt üretimi kesildi.", retryable: false })
          end
          generation.publish!
        else
          Jobs.enqueue(:sorumatik_generate_answer, generation_id: generation.id)
        end
      end

      # 2. Recover orphaned 'soru-cozumu' topics where the client failed to post an answer after 2 minutes
      recover_orphaned_topics!
    end

    private

    def recover_orphaned_topics!
      return unless SiteSetting.gemini_ai_solve_enabled

      bot_username = SiteSetting.gemini_ai_solve_bot_username.presence || "sorumatik_ai"
      bot = User.find_by_username(bot_username)
      return unless bot

      cat_setting = SiteSetting.respond_to?(:gemini_ai_solve_category_ids) ? SiteSetting.gemini_ai_solve_category_ids.to_s.strip : ""
      if !cat_setting.empty?
        category_ids = cat_setting.split("|").map { |id| id.strip.to_i }.reject(&:zero?)
        orphaned_topics = Topic.left_joins(:tags)
                               .where("tags.name = 'soru-cozumu' OR topics.category_id IN (?)", category_ids)
                               .where("topics.created_at > ? AND topics.created_at < ?", 24.hours.ago, 2.minutes.ago)
                               .where(posts_count: 1)
                               .where(deleted_at: nil)
                               .distinct
      else
        orphaned_topics = Topic.joins(:tags)
                               .where(tags: { name: "soru-cozumu" })
                               .where("topics.created_at > ? AND topics.created_at < ?", 24.hours.ago, 2.minutes.ago)
                               .where(posts_count: 1)
                               .where(deleted_at: nil)
      end

      orphaned_topics.find_each do |topic|
        first_post = topic.first_post
        next unless first_post && first_post.deleted_at.nil? && first_post.post_type == Post.types[:regular]
        next if first_post.user_id == bot.id

        has_bot_answer = topic.posts.where(user_id: bot.id).exists?
        next if has_bot_answer

        gen = SorumatikOcr::AiGeneration.find_by(source_post_id: first_post.id)
        next if gen && %w[completed persisting generating].include?(gen.state)

        Rails.logger.info("[Sorumatik AI] SorumatikRecoverAnswers recovering orphaned topic ##{topic.id}")
        begin
          SorumatikOcr::AnswerGeneration.start!(first_post, fallback: true)
        rescue StandardError => e
          Rails.logger.warn("[Sorumatik AI] Recovery failed for topic ##{topic.id}: #{e.class} - #{e.message}")
        end
      end
    end
  end
end
