# frozen_string_literal: true

module ::Jobs
  class SorumatikGenerateAnswer < ::Jobs::Base
    sidekiq_options retry: false

    def execute(args)
      generation = SorumatikOcr::AiGeneration.find_by(id: args[:generation_id])
      SorumatikOcr::AnswerGeneration.new(generation).run! if generation
    end
  end
end
