# frozen_string_literal: true

module SorumatikOcr
  class AiGenerationsController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    before_action :ensure_logged_in, only: %i[active create]

    def active
      recent_generations = AiGeneration.where(user_id: current_user.id)
        .where("state IN ('queued', 'generating', 'persisting') OR (state = 'completed' AND updated_at > ?)", 10.minutes.ago)
        .order(updated_at: :desc)
        .limit(10)

      snapshots = recent_generations.map do |gen|
        source = gen.source_post
        next nil if source.nil? || source.deleted_at.present? || !guardian.can_see?(source.topic)
        gen.snapshot
      end.compact

      render json: { success: true, generations: snapshots }
    end

    def create
      source = Post.find_by(id: params[:source_post_id])
      source ||= Topic.find_by(id: params[:topic_id])&.first_post if params[:source_post_id].blank?
      raise Discourse::NotFound unless source && source.topic_id == params[:topic_id].to_i
      raise Discourse::InvalidAccess unless source.deleted_at.nil? && source.post_type == Post.types[:regular]
      guardian.ensure_can_see!(source.topic)
      raise Discourse::InvalidAccess unless source.user_id == current_user.id || current_user.staff?
      unless SiteSetting.gemini_ai_solve_enabled
        return render_json_error("AI solve is disabled", status: 503)
      end
      generation = AnswerGeneration.start!(source, fallback: true)
      render json: generation.snapshot, status: generation.terminal? ? 200 : 202
    rescue GeminiAnswerStream::Failure => e
      render json: { success: false, error: e.code }, status: 409
    end

    def by_source
      source = Post.find_by(id: params[:source_post_id])
      raise Discourse::NotFound unless source && source.deleted_at.nil?
      guardian.ensure_can_see!(source.topic)
      generation = AiGeneration.find_by(source_post_id: source.id)
      raise Discourse::NotFound unless generation
      render json: generation.snapshot
    end

    def by_topic
      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::NotFound unless topic
      guardian.ensure_can_see!(topic)

      generation = AiGeneration.where(topic_id: topic.id)
        .where("state IN ('queued', 'generating', 'persisting') OR (state = 'completed' AND updated_at > ?)", 2.minutes.ago)
        .order(updated_at: :desc, id: :desc)
        .first

      if generation
        render json: { success: true, active: !generation.terminal?, generation: generation.snapshot }
      else
        render json: { success: true, active: false, generation: nil }
      end
    end

    def show
      generation = AiGeneration.find_by!(generation_id: params[:id])
      source = generation.source_post
      raise Discourse::NotFound unless source && source.deleted_at.nil?
      guardian.ensure_can_see!(source.topic)
      render json: generation.snapshot
    end
  end
end
