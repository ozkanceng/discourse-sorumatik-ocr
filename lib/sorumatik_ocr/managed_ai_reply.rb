# frozen_string_literal: true

module SorumatikOcr
  module ManagedAiReply
    def reply_to(source_post, *args, **kwargs, &callback)
      suppress_setting = SiteSetting.gemini_ai_suppress_automation_bot_username
      suppress_bot = (suppress_setting.respond_to?(:presence) && suppress_setting.presence) || suppress_setting.to_s
      suppress_bot = "sorumatik_uzman_bot" if suppress_bot.empty?

      bot_setting = SiteSetting.gemini_ai_solve_bot_username
      bot_username = (bot_setting.respond_to?(:presence) && bot_setting.presence) || bot_setting.to_s
      bot_username = "sorumatik_ai" if bot_username.empty?

      # Gracefully skip automation bot (sorumatik_uzman_bot) on mobile/AI handled topics
      # to avoid unhandled ActiveRecord::RecordNotSaved in DiscourseAi LlmAgentTriage.
      bot = @bot_user || (respond_to?(:user) ? user : nil)
      if bot && bot.username.to_s.casecmp?(suppress_bot)
        t = source_post&.topic
        if t && (AnswerGeneration.question_topic?(t) ||
                 !t.custom_fields&.[]("ai_solve_handled").to_s.strip.empty? ||
                 (t.respond_to?(:posts) && t.posts.respond_to?(:joins) && t.posts.joins(:user).where(users: { username: bot_username }).exists?))
          Rails.logger.info("[Sorumatik AI] Gracefully skipping automation bot #{suppress_bot} in Playground for topic ##{t.id}") if defined?(Rails)
          return nil
        end
      end

      return nil if AnswerGeneration.client_owned_source?(source_post)
      if AnswerGeneration.managed_source?(source_post)
        generation = AnswerGeneration.start!(source_post)
        return generation.post
      end
      super
    end
  end
end
