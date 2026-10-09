# frozen_string_literal: true

module SorumatikOcr
  module ManagedAiReply
    def reply_to(source_post, *args, **kwargs, &callback)
      return nil if AnswerGeneration.client_owned_source?(source_post)
      if AnswerGeneration.managed_source?(source_post)
        generation = AnswerGeneration.start!(source_post)
        return generation.post
      end
      super
    end
  end
end
