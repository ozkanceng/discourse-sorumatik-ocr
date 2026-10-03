# frozen_string_literal: true

module SorumatikOcr
  module ManagedAiReply
    def reply_to(source_post, *args, **kwargs, &callback)
      if AnswerGeneration.managed_source?(source_post)
        generation = AnswerGeneration.start!(source_post)
        return generation.post
      end
      super
    end
  end
end
