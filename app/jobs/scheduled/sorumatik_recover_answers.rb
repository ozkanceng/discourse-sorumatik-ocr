# frozen_string_literal: true

module ::Jobs
  class SorumatikRecoverAnswers < ::Jobs::Scheduled
    every 1.minute

    MAX_RECOVER_ATTEMPTS = 2

    def execute(_args)
      # 1. Recover stalled AiGeneration records (queued/persisting/generating stuck > 95s)
      SorumatikOcr::AiGeneration.where(state: %w[queued persisting generating]).where("updated_at < ?", 95.seconds.ago).find_each do |generation|
        if generation.state == "generating"
          generation.with_lock do
            next unless generation.state == "generating" && generation.updated_at < 95.seconds.ago
            generation.update!(state: "failed", sequence: generation.sequence + 1,
                               error: { code: "worker_interrupted", message: "Yanıt üretimi kesildi.", retryable: true })
          end
          generation.publish!
        else
          Jobs.enqueue(:sorumatik_generate_answer, generation_id: generation.id)
        end
      end

      # 2. Retry failed generations (max 5 attempts, cooldown 30s between retries)
      recover_failed_generations!

      # 3. Recover orphaned 'soru-cozumu' topics where neither client nor server posted an answer
      recover_orphaned_topics!
    end

    private

    def recover_failed_generations!
      SorumatikOcr::AiGeneration
        .where(state: "failed")
        .where("updated_at < ?", 30.seconds.ago)
        .where("created_at > ?", 24.hours.ago)
        .find_each do |generation|
          attempts = (generation.metrics&.dig("recover_attempts") || 0).to_i
          next if attempts >= MAX_RECOVER_ATTEMPTS

          source = generation.source_post
          next if SorumatikOcr::SecurityPolicy.spam_or_ineligible_post?(source)

          error_code = (generation.error&.dig("code") || generation.error&.dig(:code)).to_s
          # Don't retry non-retryable errors (e.g. missing_api_key, access_revoked, generation_timeout, ineligible_source)
          retryable = generation.error&.dig("retryable")
          retryable = generation.error&.dig(:retryable) if retryable.nil?
          next if retryable == false && !%w[worker_interrupted persistence_failed].include?(error_code)

          Rails.logger.info(
            "[Sorumatik AI] Recovering failed generation #{generation.generation_id} " \
            "(topic ##{generation.topic_id}, attempt #{attempts + 1}/#{MAX_RECOVER_ATTEMPTS}, " \
            "error: #{error_code})"
          )

          generation.with_lock do
            next unless generation.state == "failed"
            new_state = generation.raw.present? ? "persisting" : "queued"
            generation.update!(
              state: new_state,
              error: nil,
              metrics: (generation.metrics || {}).merge("recover_attempts" => attempts + 1),
              sequence: generation.sequence + 1
            )
          end
          Jobs.enqueue(:sorumatik_generate_answer, generation_id: generation.id)
        end
    end

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
                               .where("topics.created_at > ? AND topics.created_at < ?", 24.hours.ago, 95.seconds.ago)
                               .where(posts_count: 1)
                               .where(deleted_at: nil)
                               .distinct
      else
        orphaned_topics = Topic.where(archetype: "regular")
                               .where("topics.created_at > ? AND topics.created_at < ?", 24.hours.ago, 95.seconds.ago)
                               .where(posts_count: 1)
                               .where(deleted_at: nil)
      end

      orphaned_topics.find_each do |topic|
        first_post = topic.first_post
        next unless first_post && first_post.deleted_at.nil? && first_post.post_type == Post.types[:regular]
        next if first_post.user_id == bot.id
        next if SorumatikOcr::SecurityPolicy.spam_or_ineligible_post?(first_post)

        has_bot_answer = topic.posts.where(user_id: bot.id).exists?
        next if has_bot_answer

        gen = SorumatikOcr::AiGeneration.find_by(source_post_id: first_post.id)
        next if gen && %w[completed persisting generating].include?(gen.state)

        # Track recovery attempts per topic to prevent infinite retries
        attempts = topic.custom_fields["sorumatik_recover_attempts"].to_i
        next if attempts >= MAX_RECOVER_ATTEMPTS

        # If generation exists and failed non-retryably or already exhausted recover_attempts, skip
        if gen && gen.state == "failed"
          gen_attempts = (gen.metrics&.dig("recover_attempts") || 0).to_i
          next if gen_attempts >= MAX_RECOVER_ATTEMPTS

          retryable = gen.error&.dig("retryable")
          retryable = gen.error&.dig(:retryable) if retryable.nil?
          err_code = (gen.error&.dig("code") || gen.error&.dig(:code)).to_s
          next if retryable == false && !%w[worker_interrupted persistence_failed].include?(err_code)
        end

        topic.custom_fields["sorumatik_recover_attempts"] = attempts + 1
        topic.save_custom_fields(true)

        Rails.logger.info(
          "[Sorumatik AI] SorumatikRecoverAnswers recovering orphaned topic ##{topic.id} " \
          "(attempt #{attempts + 1}/#{MAX_RECOVER_ATTEMPTS})"
        )
        begin
          SorumatikOcr::AnswerGeneration.start!(first_post, fallback: true)
        rescue StandardError => e
          Rails.logger.warn(
            "[Sorumatik AI] Recovery failed for topic ##{topic.id} " \
            "(attempt #{attempts + 1}/#{MAX_RECOVER_ATTEMPTS}): #{e.class} - #{e.message}"
          )
        end
      end
    end
  end
end
