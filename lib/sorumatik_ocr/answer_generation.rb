# frozen_string_literal: true

require "base64"
require "digest"

module SorumatikOcr
  class AnswerGeneration
    MAX_SECONDS = 90

    def self.managed_source?(source)
      return false unless SiteSetting.gemini_ai_solve_enabled && source&.user && source.topic
      return false unless source.post_type == Post.types[:regular] && source.deleted_at.nil?
      return false if [SiteSetting.gemini_ai_solve_bot_username, SiteSetting.gemini_ai_suppress_automation_bot_username].include?(source.user.username)
      return false unless Guardian.new(source.user).can_see?(source.topic)
      return true if AiGeneration.exists?(source_post_id: source.id)
      return false unless source.topic.tags.exists?(name: "soru-cozumu")
      return true if source.post_number == 1
      bot = SiteSetting.gemini_ai_solve_bot_username
      source.raw.match?(/@#{Regexp.escape(bot)}\b/i) || source.reply_to_post&.user&.username == bot
    end

    def self.start!(source)
      generation = nil
      source.with_lock do
        unless AiGeneration.exists?(source_post_id: source.id)
          # Apply once for every entry point, including automatic bot jobs.
          RateLimiter.new(source.user, "sorumatik_ai_solve", SiteSetting.gemini_ai_solve_rate_limit_per_minute, 1.minute).performed!
        end
        generation = AiGeneration.find_or_create_by!(source_post_id: source.id) do |g|
          g.topic_id = source.topic_id
          g.user_id = source.user_id
        end
        generation.with_lock do
          # Adopt already persisted legacy answers without generating another one.
          if generation.state == "queued"
            bot = User.find_by_username(SiteSetting.gemini_ai_solve_bot_username)
            replies = source.topic.posts.where(user_id: bot&.id).where("post_number > ?", source.post_number)
            replies = replies.where(reply_to_post_number: source.post_number == 1 ? [nil, 1] : source.post_number)
            if (post = replies.order(:post_number).first)
              generation.update!(state: "completed", post_id: post.id, raw: post.raw, sequence: generation.sequence + 1)
            end
          elsif generation.state == "failed" && generation.error&.dig("code") == "persistence_failed"
            generation.update!(state: "persisting", error: nil, save_attempts: 0, sequence: generation.sequence + 1)
          end
        end
      end
      # Repeated enqueue is safe: the worker atomically claims the row. It also
      # repairs a request that crashed after commit but before enqueue.
      Jobs.enqueue(:sorumatik_generate_answer, generation_id: generation.id) if %w[queued persisting].include?(generation.state)
      generation
    end

    # Compatibility for installed clients that already have generated text.
    # Import and generation share the same source lock and unique record.
    def self.import!(source, raw)
      generation = nil
      source.with_lock do
        generation = AiGeneration.find_by(source_post_id: source.id)
        if generation
          return generation if generation.state == "completed" && generation.raw == raw.strip
          raise GeminiAnswerStream::Failure.new("answer_conflict")
        end
        bot = User.find_by_username(SiteSetting.gemini_ai_solve_bot_username)
        existing = source.topic.posts.where(user_id: bot&.id).where("post_number > ?", source.post_number)
          .where(reply_to_post_number: source.post_number == 1 ? [nil, 1] : source.post_number).order(:post_number).first
        raise GeminiAnswerStream::Failure.new("answer_conflict") if existing && existing.raw != raw.strip
        generation = AiGeneration.create!(source_post_id: source.id, topic_id: source.topic_id, user_id: source.user_id,
                                          raw: raw.strip, state: existing ? "completed" : "persisting", post_id: existing&.id)
      end
      new(generation).persist! unless generation.state == "completed"
      generation.reload
    end

    def initialize(generation)
      @generation = generation
    end

    def run!
      claimed = false
      @generation.with_lock do
        if @generation.state == "queued"
          @generation.update!(state: "generating", sequence: @generation.sequence + 1)
          claimed = true
        end
      end
      return persist! if !claimed && @generation.state == "persisting"
      return unless claimed

      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @deadline = @started + MAX_SECONDS
      @metrics = { "queue_ms" => ((Time.current - @generation.created_at) * 1000).round }
      @generation.publish!
      source = @generation.source_post
      raise GeminiAnswerStream::Failure.new("access_revoked") unless source && source.deleted_at.nil? && Guardian.new(source.user).can_see?(source.topic)
      key = SiteSetting.gemini_ocr_api_key.presence || ENV["GEMINI_API_KEY"]
      raise GeminiAnswerStream::Failure.new("missing_api_key") if key.blank?
      model = SiteSetting.gemini_ai_solve_model
      prompt = SiteSetting.gemini_ai_solve_system_prompt
      @metrics.merge!("model" => model, "prompt_sha256" => Digest::SHA256.hexdigest(prompt))
      contents = build_contents(source)
      @metrics["images_ready_ms"] = elapsed
      payload = {
        contents: contents,
        systemInstruction: { parts: [{ text: prompt }] },
        generationConfig: { temperature: 0.3, maxOutputTokens: 16_384,
                            thinkingConfig: model.start_with?("gemini-2.5") ? { thinkingBudget: -1 } : { thinkingLevel: "high" } },
      }
      @metrics["upstream_sent_ms"] = elapsed
      raw = +""
      last_publish = -100
      GeminiAnswerStream.new(model: model, api_key: key, payload: payload, deadline: @deadline, metrics: @metrics).each_delta do |delta|
        @metrics["first_text_ms"] ||= elapsed
        raw << delta
        if elapsed - last_publish >= 80
          save_snapshot!(raw.strip)
          last_publish = elapsed
        end
      end
      @metrics["last_text_ms"] = elapsed
      save_snapshot!(raw.strip, state: "persisting")
      persist!
    rescue StandardError => e
      code = e.respond_to?(:code) ? e.code : "generation_failed"
      @generation.reload
      unless @generation.terminal?
        @generation.update!(state: "failed", sequence: @generation.sequence + 1,
                            raw: raw&.strip.presence || @generation.raw,
                            metrics: @metrics || {}, error: { code: code, message: "Yanıt tamamlanamadı.", retryable: false })
        @generation.publish!
      end
      Rails.logger.warn("sorumatik_ai failed generation_id=#{@generation.generation_id} code=#{code} error=#{e.class}")
    ensure
      log_metrics if @metrics
    end

    def persist!
      save_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      source = @generation.source_post
      raise "Answer source is missing" unless source
      creator = nil
      # Same lock order as start!/import!. PostCreator also locks the source
      # while adding reply relationships, so taking the generation first can
      # deadlock with a concurrent reconnect request.
      source.with_lock do
        @generation.with_lock do
          return unless @generation.state == "persisting"
          raise "Answer access revoked" unless source.deleted_at.nil? && Guardian.new(source.user).can_see?(source.topic)
          bot = User.find_by_username(SiteSetting.gemini_ai_solve_bot_username)
          raise "Configured answer bot is missing" unless bot
          topic = Topic.find_by(id: @generation.topic_id)
          raise "Topic is missing" unless topic
          creator = PostCreator.new(bot, topic_id: topic.id, raw: @generation.raw,
                                    reply_to_post_number: source.post_number, skip_validations: true,
                                    skip_jobs: true, skip_events: true,
                                    custom_fields: { "sorumatik_generation_id" => @generation.generation_id })
          post = creator.create!
          # A post hook must not silently rewrite the content already streamed.
          raise "Saved answer differs from streamed answer" unless post&.persisted? && post.raw == @generation.raw
          metrics = @generation.metrics.merge("saved_at" => Time.current.iso8601(3),
                                              "save_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - save_started) * 1000).round,
                                              "total_ms" => ((Time.current - @generation.created_at) * 1000).round)
          @generation.update!(state: "completed", post_id: post.id, error: nil,
                              metrics: metrics, sequence: @generation.sequence + 1)
        end
      end
      @generation.publish!
      begin
        creator.trigger_after_events
        creator.enqueue_jobs
      rescue StandardError => e
        # Notification errors cannot invalidate or duplicate a committed answer.
        Rails.logger.warn("sorumatik_ai post_hooks_failed generation_id=#{@generation.generation_id} error=#{e.class}")
      end
      log_metrics unless @metrics
    rescue StandardError => e
      # The transaction above rolls back both post creation and completion. The
      # durable raw draft predates it, so saving never invokes Gemini again.
      @generation.reload
      @generation.with_lock do
        return if @generation.state == "completed"
        attempts = @generation.save_attempts + 1
        @generation.update!(save_attempts: attempts, state: attempts < 3 ? "persisting" : "failed",
                            sequence: @generation.sequence + 1,
                            error: { code: "persistence_failed", message: "Yanıt hazır; kaydedilemedi.", retryable: true })
      end
      @generation.publish!
      Jobs.enqueue_in(2.seconds, :sorumatik_generate_answer, generation_id: @generation.id) if @generation.state == "persisting"
      Rails.logger.warn("sorumatik_ai save_failed generation_id=#{@generation.generation_id} error=#{e.class}")
    end

    private

    def elapsed
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started) * 1000).round
    end

    def save_snapshot!(raw, state: "generating")
      @generation.update!(raw: raw, state: state, metrics: @metrics, sequence: @generation.sequence + 1)
      @generation.publish!
    end

    def build_contents(source)
      recent = source.topic.posts.where(post_type: Post.types[:regular]).where("post_number <= ?", source.post_number).order(post_number: :desc).limit(20).to_a
      history = ([source.topic.first_post] + recent).compact.uniq(&:id).sort_by(&:post_number)
      guardian = Guardian.new(source.user)
      history.select! { |post| post.deleted_at.nil? && guardian.can_see?(post) }
      bot_id = User.find_by_username(SiteSetting.gemini_ai_solve_bot_username)&.id
      history.map do |post|
        parts = []
        if post.id == source.id || post.post_number == 1
          post.uploads.each do |upload|
            next unless %w[png jpg jpeg webp].include?(upload.extension.to_s.downcase)
            raise GeminiAnswerStream::Failure.new("image_too_large") if upload.filesize.to_i > 10.megabytes
            remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise GeminiAnswerStream::Failure.new("generation_timeout") if remaining <= 0
            bytes = Timeout.timeout([remaining, 10].min) do
              path = Discourse.store.path_for(upload) rescue nil
              if path && File.file?(path)
                File.binread(path)
              else
                url = Discourse.store.cdn_url(upload.url)
                url = "https:#{url}" if url.start_with?("//")
                url = "#{Discourse.base_url}#{url}" unless url.start_with?("http")
                uri = URI(url)
                response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 5) { |http| http.get(uri.request_uri) }
                raise GeminiAnswerStream::Failure.new("image_unavailable") unless response.is_a?(Net::HTTPSuccess)
                response.body
              end
            end
            raise GeminiAnswerStream::Failure.new("image_too_large") if bytes.bytesize > 10.megabytes
            mime = upload.extension.to_s.downcase == "png" ? "image/png" : upload.extension.to_s.downcase == "webp" ? "image/webp" : "image/jpeg"
            parts << { inline_data: { mime_type: mime, data: Base64.strict_encode64(bytes) } }
          end
        end
        parts << { text: post.raw }
        { role: post.user_id == bot_id ? "model" : "user", parts: parts }
      end
    end

    def log_metrics
      Rails.logger.info("sorumatik_ai_metrics #{JSON.generate(@generation.reload.metrics.merge("generation_id" => @generation.generation_id, "state" => @generation.state))}")
    end
  end
end
