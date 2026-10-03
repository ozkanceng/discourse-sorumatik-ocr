# frozen_string_literal: true

module SorumatikOcr
  # Legacy SSE transport only. Generation always belongs to the durable job.
  class AiSolveController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    include ActionController::Live
    skip_before_action :check_xhr
    skip_before_action :verify_authenticity_token
    skip_before_action :redirect_to_login_if_required
    before_action :ensure_logged_in

    def stream
      return render_json_error("AI solve is disabled", status: 503) unless SiteSetting.gemini_ai_solve_enabled
      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::NotFound unless topic
      guardian.ensure_can_see!(topic)
      source = params[:source_post_id].present? ? topic.posts.find(params[:source_post_id]) : topic.first_post
      raise Discourse::InvalidAccess unless source && source.deleted_at.nil? && source.post_type == Post.types[:regular] && source.user_id == current_user.id
      generation = AnswerGeneration.start!(source)
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
      previous = ""
      sequence = -1
      loop do
        generation.reload
        guardian.ensure_can_see!(topic.reload)
        if generation.sequence > sequence
          snapshot = generation.snapshot
          delta = snapshot[:raw].start_with?(previous) ? snapshot[:raw][previous.length..-1] : ""
          response.stream.write("data: #{snapshot.merge(delta: delta).to_json}\n\n")
          sequence, previous = generation.sequence, snapshot[:raw]
        end
        break if generation.terminal? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.25
      end
    rescue IOError, ActionController::Live::ClientDisconnected
      # Disconnecting the legacy transport never restarts or cancels the job.
    ensure
      response.stream.close
    end
  end
end
