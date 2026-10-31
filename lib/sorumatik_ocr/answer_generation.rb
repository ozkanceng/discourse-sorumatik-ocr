# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"
require_relative "security_policy"

module SorumatikOcr
  class AnswerGeneration
    MAX_SECONDS = 180
    CLIENT_LEASE_SECONDS = 90
    MAX_GENERATION_ATTEMPTS = 3
    MAX_SAVE_ATTEMPTS = 3

    def self.resolve_solve_max_output_tokens(model, level = "default")
      m = model.to_s.strip.downcase
      lvl = level.to_s.strip.downcase
      if m.start_with?("gemini-2.5", "gemini-3")
        %w[minimal low].include?(lvl) ? 12_288 : 32_768
      else
        8_192
      end
    end

    def self.client_owned_source?(source, lease_seconds: CLIENT_LEASE_SECONDS)
      return false unless source
      # Protocol 3 and above is strictly server-owned and generated on the server!
      return false if source.custom_fields["mobile_answer_protocol"].to_i >= 3
      # Legacy protocol 2 client-edge solve only
      return false unless source.custom_fields["client_edge_solve"].to_s == "true" &&
                          source.custom_fields["mobile_answer_protocol"].to_i == 2

      created = source.created_at || (Time.respond_to?(:current) ? Time.current : Time.now)
      current = Time.respond_to?(:current) ? Time.current : Time.now
      (current - created) < lease_seconds
    end

    def self.question_topic?(topic)
      return false unless topic
      return true if topic.respond_to?(:tags) && topic.tags.respond_to?(:exists?) && topic.tags.exists?(name: "soru-cozumu")
      return true if topic.respond_to?(:custom_fields) && topic.custom_fields["client_edge_solve"].to_s == "true"

      first_post = topic.respond_to?(:first_post) ? topic.first_post : nil
      if first_post&.respond_to?(:custom_fields)
        return true if first_post.custom_fields["client_edge_solve"].to_s == "true" ||
                       first_post.custom_fields["mobile_answer_protocol"].to_i >= 3
      end

      # Kategori bazlı filtreleme:
      # Eğer yönetici panelinden kategori ID'leri açıkça sınırlandırılmışsa (örn: "6|163"), yalnızca o kategoriler kabul edilir.
      setting = SiteSetting.respond_to?(:gemini_ai_solve_category_ids) ? SiteSetting.gemini_ai_solve_category_ids.to_s.strip : ""
      if !setting.empty?
        category_id = topic.respond_to?(:category_id) ? topic.category_id : nil
        if category_id
          allowed = setting.split("|").map { |id| id.strip.to_i }.reject(&:zero?)
          return true if allowed.include?(category_id)
        end
        return false
      end

      # Kategori ayarı boş bırakılmışsa (varsayılan), tüm genel forum kategorilerindeki soruları kapsar.
      # Özel mesajlar (PM) otomatik soru konusu sayılmaz.
      return false if topic.respond_to?(:private_message?) && topic.private_message?

      true
    end

    def self.managed_source?(source)
      return false if client_owned_source?(source)
      return false unless SiteSetting.gemini_ai_solve_enabled && source&.user && source.topic
      return false unless source.post_type == Post.types[:regular] && source.deleted_at.nil?
      return false if source.user.username == SiteSetting.gemini_ai_solve_bot_username
      return false if SecurityPolicy.spam_or_ineligible_post?(source)
      return false unless Guardian.new(source.user).can_see?(source.topic)
      return true if source.custom_fields["mobile_answer_protocol"].to_i >= 3
      return true if defined?(AiGeneration) && AiGeneration.respond_to?(:exists?) && AiGeneration.exists?(source_post_id: source.id)
      return false unless question_topic?(source.topic)
      return true if source.post_number == 1
      bot = SiteSetting.gemini_ai_solve_bot_username.presence || "sorumatik_ai"
      mentioned = source.raw.to_s.match?(/@(?:#{Regexp.escape(bot)}|sorumatik_ai|sorumatik-ai|sorumatik_uzman_bot)\b/i)
      replied_to_bot = source.reply_to_post&.user&.username.to_s.casecmp?(bot) ||
                       %w[sorumatik_ai sorumatik-ai sorumatik_uzman_bot].include?(source.reply_to_post&.user&.username.to_s.downcase)
      mentioned || replied_to_bot
    end

    def self.start!(source, fallback: false)
      raise GeminiAnswerStream::Failure.new("client_owned_source") if !fallback && client_owned_source?(source)
      raise GeminiAnswerStream::Failure.new("ineligible_source") if SecurityPolicy.spam_or_ineligible_post?(source)
      generation = nil
      source.with_lock do
        unless fallback || AiGeneration.exists?(source_post_id: source.id)
          raw_limit = SiteSetting.respond_to?(:gemini_ai_solve_rate_limit_per_minute) ? SiteSetting.gemini_ai_solve_rate_limit_per_minute.to_i : 15
          solve_limit = raw_limit <= 0 ? 15 : [raw_limit, 120].min
          RateLimiter.new(source.user, "sorumatik_ai_solve", solve_limit, 1.minute).performed!
        end
        generation = AiGeneration.find_or_create_by!(source_post_id: source.id) do |g|
          g.topic_id = source.topic_id
          g.user_id = source.user_id
        end
        generation.update!(metrics: (generation.metrics || {}).merge("fallback" => true)) if fallback
        generation.with_lock do
          # Adopt already persisted legacy answers without generating another one.
          if generation.state == "queued"
            bot = defined?(::User) && ::User.respond_to?(:find_by_username) ? ::User.find_by_username(SiteSetting.gemini_ai_solve_bot_username) : nil
            replies = source.topic.posts.where(user_id: bot&.id).where("post_number > ?", source.post_number)
            replies = replies.where(reply_to_post_number: source.post_number == 1 ? [nil, 1] : source.post_number)
            if (post = replies.order(:post_number).first)
              clean_raw = post.raw.to_s.gsub("\r\n", "\n").strip
              update_attrs = {
                state: "completed",
                post_id: post.id,
                raw: clean_raw,
                sequence: generation.sequence + 1
              }
              update_attrs[:content_sha256] = Digest::SHA256.hexdigest(clean_raw) if generation.respond_to?(:content_sha256)
              update_attrs[:provider_completed] = true if generation.respond_to?(:provider_completed)
              generation.update!(update_attrs)
            end
          elsif generation.state == "failed"
            err_code = (generation.error&.dig("code") || generation.error&.dig(:code)).to_s
            is_non_retryable = generation.error&.dig("retryable") == false || generation.error&.dig(:retryable) == false
            if err_code == "persistence_failed"
              generation.update!(state: "persisting", error: nil, save_attempts: 0, sequence: generation.sequence + 1)
            elsif fallback && !is_non_retryable
              # Retry failed generation only when the failure was marked retryable
              generation.update!(state: !generation.raw.to_s.empty? ? "persisting" : "queued", error: nil, sequence: generation.sequence + 1)
            end
          end
        end
      end
      # Repeated enqueue is safe: the worker atomically claims the row. It also
      # repairs a request that crashed after commit but before enqueue.
      Jobs.enqueue(:sorumatik_generate_answer, generation_id: generation.id) if %w[queued persisting].include?(generation.state)
      generation
    end

    CLIENT_CLAIM_TOKEN = /\A[A-Za-z0-9_-]{16,64}\z/

    def self.client_execution_id(token)
      "client-#{token}"
    end

    def self.client_claimed?(generation, token)
      !token.to_s.empty? && generation.state == "generating" &&
        generation.execution_id == client_execution_id(token)
    end

    # Hands a generation that has produced no text yet to the mobile client.
    # The worker only claims "queued" rows, so it skips a client-owned
    # "generating" row; if the client disappears, stale-heartbeat recovery
    # fails it as retryable and the server generates the answer again.
    def self.client_claim!(source, token)
      raise GeminiAnswerStream::Failure.new("invalid_claim_token") unless token.to_s.match?(CLIENT_CLAIM_TOKEN)
      generation = nil
      claimed = false
      source.with_lock do
        generation = AiGeneration.find_or_create_by!(source_post_id: source.id) do |g|
          g.topic_id = source.topic_id
          g.user_id = source.user_id
        end
        generation.with_lock do
          no_text = generation.raw.to_s.strip.empty? && generation.post_id.nil?
          claimable = client_claimed?(generation, token) ||
                      (no_text && %w[queued failed].include?(generation.state))
          if claimable
            attrs = { state: "generating", error: nil, sequence: generation.sequence + 1 }
            attrs[:execution_id] = client_execution_id(token) if generation.respond_to?(:execution_id)
            attrs[:heartbeat_at] = Time.current if generation.respond_to?(:heartbeat_at)
            generation.update!(attrs)
            claimed = true
          end
        end
      end
      generation.publish! if claimed
      [generation, claimed]
    end

    # Returns a client-owned generation to the server queue when the client
    # cannot generate (for example when the proxy is full).
    def self.client_release!(source, token)
      generation = AiGeneration.find_by(source_post_id: source.id)
      return [nil, false] unless generation
      released = false
      generation.with_lock do
        if client_claimed?(generation, token) && generation.raw.to_s.strip.empty?
          attrs = { state: "queued", sequence: generation.sequence + 1 }
          attrs[:execution_id] = nil if generation.respond_to?(:execution_id)
          attrs[:heartbeat_at] = nil if generation.respond_to?(:heartbeat_at)
          generation.update!(attrs)
          released = true
        end
      end
      if released
        generation.publish!
        Jobs.enqueue(:sorumatik_generate_answer, generation_id: generation.id)
      end
      [generation, released]
    end

    def self.import!(source, raw, claim_token: nil)
      generation = nil
      cleaned_raw = raw.to_s.gsub("\r\n", "\n").strip
      return nil if cleaned_raw.empty?

      source.with_lock do
        generation = AiGeneration.find_by(source_post_id: source.id)
        if generation
          if generation.state == "generating" && !client_claimed?(generation, claim_token)
            raise GeminiAnswerStream::Failure.new("answer_in_progress")
          end
          if generation.state == "completed" && generation.post_id
            post = Post.find_by(id: generation.post_id)
            raise GeminiAnswerStream::Failure.new("answer_missing") unless post && post.deleted_at.nil?
            post_clean = post.raw.to_s.gsub("\r\n", "\n").strip
            raise GeminiAnswerStream::Failure.new("answer_conflict") if post_clean != cleaned_raw
            attrs = { raw: cleaned_raw }
            attrs[:content_sha256] = Digest::SHA256.hexdigest(cleaned_raw) if generation.respond_to?(:content_sha256)
            generation.update!(attrs)
            return generation
          end

          gen_clean = generation.raw.to_s.gsub("\r\n", "\n").strip
          if !generation.raw.to_s.empty? && gen_clean != cleaned_raw && %w[persisting failed].include?(generation.state)
            raise GeminiAnswerStream::Failure.new("answer_conflict")
          end
          update_attrs = {
            state: "persisting",
            raw: cleaned_raw,
            error: nil,
            sequence: generation.sequence + 1
          }
          update_attrs[:content_sha256] = Digest::SHA256.hexdigest(cleaned_raw) if generation.respond_to?(:content_sha256)
          update_attrs[:provider_completed] = true if generation.respond_to?(:provider_completed)
          generation.update!(update_attrs)
        else
          bot = defined?(::User) && ::User.respond_to?(:find_by_username) ? ::User.find_by_username(SiteSetting.gemini_ai_solve_bot_username) : nil
          existing = source.topic.posts.where(user_id: bot&.id).where("post_number > ?", source.post_number)
            .where(reply_to_post_number: source.post_number == 1 ? [nil, 1] : source.post_number).order(:post_number).first

          if existing
            existing_clean = existing.raw.to_s.gsub("\r\n", "\n").strip
            raise GeminiAnswerStream::Failure.new("answer_conflict") if existing_clean != cleaned_raw
            create_attrs = {
              source_post_id: source.id,
              topic_id: source.topic_id,
              user_id: source.user_id,
              raw: cleaned_raw,
              state: "completed",
              post_id: existing.id
            }
            create_attrs[:content_sha256] = Digest::SHA256.hexdigest(cleaned_raw) if AiGeneration.column_names.include?("content_sha256")
            create_attrs[:provider_completed] = true if AiGeneration.column_names.include?("provider_completed")
            generation = AiGeneration.create!(create_attrs)
          else
            create_attrs = {
              source_post_id: source.id,
              topic_id: source.topic_id,
              user_id: source.user_id,
              raw: cleaned_raw,
              state: "persisting"
            }
            create_attrs[:content_sha256] = Digest::SHA256.hexdigest(cleaned_raw) if AiGeneration.column_names.include?("content_sha256")
            create_attrs[:provider_completed] = true if AiGeneration.column_names.include?("provider_completed")
            generation = AiGeneration.create!(create_attrs)
          end
        end
      end
      new(generation).persist! unless generation.state == "completed"
      generation.reload
    end

    def initialize(generation)
      @generation = generation
      @execution_id = SecureRandom.uuid
    end

    def run!
      claimed = false
      @generation.with_lock do
        if @generation.state == "queued"
          current_attempts = (@generation.respond_to?(:attempts) ? @generation.attempts.to_i : 0) + 1
          if current_attempts > MAX_GENERATION_ATTEMPTS
            @generation.update!(
              state: "failed",
              sequence: @generation.sequence + 1,
              error: { code: "max_attempts_exceeded", message: "Maksimum deneme sayısına ulaşıldı.", retryable: false }
            )
            @generation.publish!
            return
          end

          claim_attrs = {
            state: "generating",
            sequence: @generation.sequence + 1
          }
          claim_attrs[:execution_id] = @execution_id if @generation.respond_to?(:execution_id)
          claim_attrs[:heartbeat_at] = Time.current if @generation.respond_to?(:heartbeat_at)
          claim_attrs[:attempts] = current_attempts if @generation.respond_to?(:attempts)
          @generation.update!(claim_attrs)
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
      raise GeminiAnswerStream::Failure.new("ineligible_source") if SecurityPolicy.spam_or_ineligible_post?(source)
      is_fallback = @generation.metrics&.[]("fallback") == true
      raise GeminiAnswerStream::Failure.new("client_owned_source") if !is_fallback && self.class.client_owned_source?(source)
      key = SorumatikOcr.resolve_api_key
      raise GeminiAnswerStream::Failure.new("missing_api_key") if key.to_s.strip.empty?
      model = SecurityPolicy.resolve_text_model(
        nil,
        site_setting: SiteSetting,
        setting_model: SiteSetting.gemini_ai_solve_model,
        fallback: "gemini-2.5-flash"
      )
      prompt = SiteSetting.gemini_ai_solve_system_prompt
      @metrics.merge!("model" => model, "prompt_sha256" => Digest::SHA256.hexdigest(prompt))
      contents = build_contents(source)
      @metrics["images_ready_ms"] = elapsed
      raw_level = SiteSetting.respond_to?(:gemini_ai_solve_thinking_level) ? SiteSetting.gemini_ai_solve_thinking_level.to_s.strip.downcase : "default"
      level = %w[default minimal low medium high].include?(raw_level) ? raw_level : "default"
      gen_config = { maxOutputTokens: self.class.resolve_solve_max_output_tokens(model, level) }
      if model.to_s.start_with?("gemini-2.5")
        if level != "default"
          budget = case level
                   when "minimal" then 0
                   when "low" then 1024
                   when "medium" then 2048
                   else 4096
                   end
          gen_config[:thinkingConfig] = { thinkingBudget: budget }
        end
      elsif model.to_s.start_with?("gemini-3")
        if level != "default"
          effective_level = level
          if effective_level == "minimal" && model.to_s.match?(/gemini-3\.(?:[78]|1)/)
            effective_level = "low"
          end
          gen_config[:thinkingConfig] = { thinkingLevel: effective_level }
        end
      end

      payload = {
        contents: contents,
        systemInstruction: { parts: [{ text: prompt }] },
        generationConfig: gen_config,
      }
      @metrics["upstream_sent_ms"] = elapsed
      raw = +""
      last_publish = -100
      last_heartbeat = -100

      GeminiAnswerStream.new(model: model, api_key: key, payload: payload, deadline: @deadline, metrics: @metrics).each_delta do |delta|
        @metrics["first_text_ms"] ||= elapsed
        raw << delta

        # Worker verification and heartbeat
        if elapsed - last_heartbeat >= 2000
          if @generation.respond_to?(:heartbeat_at)
            # Stale worker protection: reject delayed worker output if overtaken
            if @generation.respond_to?(:execution_id) && @generation.execution_id && !@generation.execution_id.empty? && @generation.execution_id != @execution_id
              raise GeminiAnswerStream::Failure.new("worker_overtaken")
            end
            now = Time.current
            hb_cols = { heartbeat_at: now }
            hb_cols[:updated_at] = now if @generation.respond_to?(:updated_at)
            @generation.update_columns(hb_cols) rescue nil
          end
          last_heartbeat = elapsed
        end

        if elapsed - last_publish >= 80
          save_snapshot!(raw.strip)
          last_publish = elapsed
        end
      end

      @metrics["last_text_ms"] = elapsed
      cleaned_final = raw.strip
      raise GeminiAnswerStream::Failure.new("empty_generation") if cleaned_final.empty?

      # Provider completed cleanly (hit STOP without exception)
      final_attrs = {
        state: "persisting",
        raw: cleaned_final,
        metrics: @metrics,
        sequence: @generation.sequence + 1
      }
      final_attrs[:content_sha256] = Digest::SHA256.hexdigest(cleaned_final) if @generation.respond_to?(:content_sha256)
      final_attrs[:provider_completed] = true if @generation.respond_to?(:provider_completed)
      @generation.update!(final_attrs)
      @generation.publish!

      persist!
    rescue StandardError => e
      code = e.respond_to?(:code) ? e.code : "generation_failed"
      @generation.reload
      unless @generation.terminal?
        current_attempts = @generation.respond_to?(:attempts) ? @generation.attempts.to_i : 1
        is_transient = (e.respond_to?(:retryable) && e.retryable) ||
                       %w[provider_429 provider_500 provider_502 provider_503 provider_504 upstream_429 upstream_503 provider_connection_failed].include?(code.to_s)
        
        if is_transient && current_attempts < MAX_GENERATION_ATTEMPTS
          @generation.update!(
            state: "queued",
            sequence: @generation.sequence + 1,
            metrics: @metrics || {},
            error: { code: code, message: "Geçici bağlantı hatası, yeniden deneniyor...", retryable: true }
          )
          @generation.publish!
          Jobs.enqueue_in(2.seconds, :sorumatik_generate_answer, generation_id: @generation.id)
        else
          stripped_raw = raw ? raw.strip : ""
          final_raw = stripped_raw.empty? ? @generation.raw : stripped_raw
          @generation.update!(
            state: "failed",
            sequence: @generation.sequence + 1,
            raw: final_raw,
            metrics: @metrics || {},
            error: { code: code, message: "Yanıt tamamlanamadı.", retryable: false }
          )
          @generation.publish!
        end
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

      # Absolute guard: never publish partial text as completed answer!
      if @generation.respond_to?(:provider_completed) && !@generation.provider_completed
        raise "Cannot persist incomplete provider answer"
      end

      # Same lock order as start!/import!. PostCreator also locks the source
      # while adding reply relationships, so taking the generation first can
      # deadlock with a concurrent reconnect request.
      source.with_lock do
        @generation.with_lock do
          return unless @generation.state == "persisting"
          raise "Answer access revoked" unless source.deleted_at.nil? && Guardian.new(source.user).can_see?(source.topic)
          bot_username = SiteSetting.gemini_ai_solve_bot_username.to_s.strip
          bot = (defined?(::User) && ::User.respond_to?(:find_by_username) && !bot_username.empty?) ? ::User.find_by_username(bot_username) : nil
          bot ||= (defined?(Discourse) && Discourse.respond_to?(:system_user) ? Discourse.system_user : nil)
          raise "Configured answer bot is missing" unless bot
          topic = Topic.find_by(id: @generation.topic_id)
          raise "Topic is missing" unless topic
          creator = PostCreator.new(bot, topic_id: topic.id, raw: @generation.raw,
                                    reply_to_post_number: source.post_number, skip_validations: true,
                                    skip_guardian: true,
                                    skip_jobs: true, skip_events: true,
                                    custom_fields: { "sorumatik_generation_id" => @generation.generation_id })
          post = creator.create!
          raise "Post was not persisted" unless post&.persisted?
          # If Discourse normalized whitespace or fancy quotes, align raw without rolling back
          post_clean = post.raw.to_s.gsub("\r\n", "\n").strip
          gen_clean = @generation.raw.to_s.gsub("\r\n", "\n").strip
          if post_clean != gen_clean
            @generation.update_columns(raw: post.raw) rescue nil
          end
          metrics = (@generation.metrics || {}).merge("saved_at" => Time.current.iso8601(3),
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
        Rails.logger.warn("sorumatik_ai post_hooks_failed generation_id=#{@generation.generation_id} error=#{e.class} message=#{e.message}")
      end
      log_metrics unless @metrics
    rescue StandardError => e
      # The transaction above rolls back both post creation and completion. The
      # durable raw draft predates it, so saving never invokes Gemini again.
      @generation.reload
      @generation.with_lock do
        return if @generation.state == "completed"
        attempts = @generation.save_attempts + 1
        @generation.update!(save_attempts: attempts, state: attempts < MAX_SAVE_ATTEMPTS ? "persisting" : "failed",
                            sequence: @generation.sequence + 1,
                            error: { code: "persistence_failed", message: "Yanıt hazır; kaydedilemedi (#{e.message}).", retryable: true })
      end
      @generation.publish!
      Jobs.enqueue_in(2.seconds, :sorumatik_generate_answer, generation_id: @generation.id) if @generation.state == "persisting"
      Rails.logger.warn("sorumatik_ai save_failed generation_id=#{@generation.generation_id} error=#{e.class} message=#{e.message}")
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
      bot_username = SiteSetting.gemini_ai_solve_bot_username.to_s.downcase
      bot_id = defined?(::User) && ::User.respond_to?(:find_by_username) ? ::User.find_by_username(SiteSetting.gemini_ai_solve_bot_username)&.id : nil
      
      contents = []
      history.each do |post|
        is_bot = (bot_id && post.user_id == bot_id) || (post.user&.username&.downcase == bot_username)
        role = is_bot ? "model" : "user"

        parts = []
        if post.id == source.id || post.post_number == 1
          uploads = post.respond_to?(:uploads) && post.uploads ? post.uploads : []
          uploads.each do |upload|
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
                fetched = SecurityPolicy.fetch_safe_image_bytes(
                  url,
                  max_bytes: 10.megabytes,
                  timeout_seconds: [remaining, 5].min
                )
                raise GeminiAnswerStream::Failure.new("image_unavailable") unless fetched
                fetched
              end
            end
            raise GeminiAnswerStream::Failure.new("image_too_large") if bytes.bytesize > 10.megabytes
            mime = upload.extension.to_s.downcase == "png" ? "image/png" : upload.extension.to_s.downcase == "webp" ? "image/webp" : "image/jpeg"
            parts << { inline_data: { mime_type: mime, data: Base64.strict_encode64(bytes) } }
          end

          # Fallback: if post.uploads is empty, extract image URLs from markdown raw (strictly SSRF-filtered to Sorumatik/CDN hosts)
          if parts.none? { |p| p.key?(:inline_data) }
            image_urls = post.raw.to_s.scan(/!\[.*?\]\(((?:https?:)?\/\/[^\s\)]+|\/uploads\/[^\s\)]+)\)/i).flatten
            image_urls.first(4).each do |raw_url|
              url = raw_url.to_s.strip
              url = "https:#{url}" if url.start_with?("//")
              url = "#{Discourse.base_url}#{url}" unless url.start_with?("http")
              next unless url =~ /\.(png|jpe?g|webp)(\?|$)/i
              ext = $1.downcase
              ext = "jpeg" if ext == "jpg"
              begin
                remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                next if remaining <= 0
                bytes = SecurityPolicy.fetch_safe_image_bytes(
                  url,
                  max_bytes: 10.megabytes,
                  timeout_seconds: [remaining, 5].min
                )
                if bytes && bytes.bytesize <= 10.megabytes
                  mime = ext == "png" ? "image/png" : ext == "webp" ? "image/webp" : "image/jpeg"
                  parts << { inline_data: { mime_type: mime, data: Base64.strict_encode64(bytes) } }
                  break
                end
              rescue => img_err
                Rails.logger.warn("[Sorumatik AI] Failed to fetch raw markdown image: #{img_err.class}")
              end
            end
          end
        end

        raw_text = post.raw.to_s.strip[0, 15_000]
        parts << { text: raw_text } unless raw_text.empty?
        next if parts.empty?

        if contents.last && contents.last[:role] == role
          contents.last[:parts].concat(parts)
        else
          contents << { role: role, parts: parts }
        end
      end

      # Gemini API requires the first turn to have role 'user'
      contents.shift while contents.first && contents.first[:role] != "user"
      contents
    end

    def log_metrics
      Rails.logger.info("sorumatik_ai_metrics #{JSON.generate(@generation.reload.metrics.merge("generation_id" => @generation.generation_id, "state" => @generation.state))}")
    end
  end
end
