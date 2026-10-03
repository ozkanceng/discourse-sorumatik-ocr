# frozen_string_literal: true

module ::Jobs
  class SorumatikRecoverAnswers < ::Jobs::Scheduled
    every 1.minute

    def execute(_args)
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
    end
  end
end
