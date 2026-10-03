# frozen_string_literal: true

module SorumatikOcr
  class AiGenerationsController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    before_action :ensure_logged_in

    def create
      source = Post.find_by(id: params[:source_post_id])
      source ||= Topic.find_by(id: params[:topic_id])&.first_post if params[:source_post_id].blank?
      raise Discourse::NotFound unless source && source.topic_id == params[:topic_id].to_i
      raise Discourse::InvalidAccess unless source.deleted_at.nil? && source.post_type == Post.types[:regular]
      guardian.ensure_can_see!(source.topic)
      raise Discourse::InvalidAccess unless source.user_id == current_user.id
      unless SiteSetting.gemini_ai_solve_enabled
        return render_json_error("AI solve is disabled", status: 503)
      end
      generation = AnswerGeneration.start!(source)
      render json: generation.snapshot, status: generation.terminal? ? 200 : 202
    end

    def show
      generation = AiGeneration.find_by!(generation_id: params[:id])
      source = generation.source_post
      raise Discourse::NotFound unless source && source.deleted_at.nil?
      guardian.ensure_can_see!(source.topic)
      raise Discourse::InvalidAccess unless generation.user_id == current_user.id
      render json: generation.snapshot
    end
  end
end
