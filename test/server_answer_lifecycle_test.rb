# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "securerandom"

class Numeric
  def minutes; self * 60; end
  def seconds; self; end
  def megabytes; self * 1024 * 1024; end
end

class Time
  def self.current; Time.now; end
end

module SiteSetting
  def self.gemini_ai_solve_enabled; true; end
  def self.gemini_ai_solve_bot_username; "sorumatik_ai"; end
  def self.gemini_ai_solve_rate_limit_per_minute; 60; end
  def self.gemini_ai_solve_model; "gemini-2.5-flash"; end
  def self.gemini_ai_solve_system_prompt; "Prompt"; end
  def self.sorumatik_ai_generation_streaming_enabled; true; end
  def self.gemini_ai_solve_thinking_level; "default"; end
  def self.gemini_ai_solve_category_ids; ""; end
end

module SorumatikOcr
  def self.resolve_api_key; "test-key"; end
end

class MessageBus
  def self.publish(*_args); true; end
end

class FakeLogger
  def info(*); end
  def warn(*); end
  def error(*); end
end

class Rails
  def self.logger
    @logger ||= FakeLogger.new
  end
end

class RateLimiter
  def initialize(*_args); end
  def performed!; true; end
end

class Jobs
  @enqueued = []
  class << self
    attr_accessor :enqueued
    def enqueue(name, args = {}); @enqueued << [name, args]; end
    def enqueue_in(delay, name, args = {}); @enqueued << [name, args, delay]; end
  end
end

class Guardian
  def initialize(*); end
  def can_see?(*); true; end
end

class Post
  def self.types; { regular: 1 }; end
end

require_relative "../lib/sorumatik_ocr/gemini_answer_stream"
require_relative "../lib/sorumatik_ocr/answer_generation"

class ServerAnswerLifecycleTest < Minitest::Test
  FakeSource = Struct.new(:id, :topic_id, :user_id, :post_number, :post_type, :deleted_at, :user, :topic, :raw, :custom_fields, :created_at) do
    def with_lock; yield; end
    def reply_to_post; nil; end
  end

  FakeTopic = Struct.new(:id, :first_post, :custom_fields, :tags) do
    def posts
      scope = Object.new
      scope.define_singleton_method(:where) { |*| scope }
      scope.define_singleton_method(:order) { |*| scope }
      scope.define_singleton_method(:limit) { |*| scope }
      scope.define_singleton_method(:to_a) { [] }
      scope.define_singleton_method(:first) { nil }
      scope
    end
  end

  FakeUser = Struct.new(:id, :username)

  FakeGeneration = Struct.new(
    :id, :generation_id, :topic_id, :source_post_id, :user_id, :post_id,
    :state, :sequence, :raw, :metrics, :error, :save_attempts,
    :content_sha256, :execution_id, :heartbeat_at, :provider_completed, :attempts,
    :created_at, :updated_at, :source_post
  ) do
    def with_lock; yield; end
    def terminal?; %w[completed failed].include?(state); end
    def publish!; true; end
    def reload; self; end
    def update!(attrs)
      attrs.each { |k, v| send("#{k}=", v) if respond_to?("#{k}=") }
    end
    def update_columns(attrs)
      update!(attrs)
    end
    def assign_attributes(attrs)
      attrs.each { |k, v| send("#{k}=", v) if respond_to?("#{k}=") }
    end
    def save!
      (@saves ||= []) << raw
    end
    def saves; @saves || []; end
  end

  def setup
    Jobs.enqueued = []
  end

  def test_protocol_3_is_never_client_owned
    source = FakeSource.new(10, 100, 1, 1, 1, nil, FakeUser.new(1, "alice"), nil, "Question", {
      "mobile_answer_protocol" => "3",
      "client_edge_solve" => "false"
    }, Time.now)

    refute SorumatikOcr::AnswerGeneration.client_owned_source?(source)
  end

  def test_protocol_2_remains_client_owned_during_lease
    source = FakeSource.new(10, 100, 1, 1, 1, nil, FakeUser.new(1, "alice"), nil, "Question", {
      "mobile_answer_protocol" => "2",
      "client_edge_solve" => "true"
    }, Time.now)

    assert SorumatikOcr::AnswerGeneration.client_owned_source?(source)
  end

  def test_protocol_3_is_managed_source
    topic = FakeTopic.new(100, nil, {}, [])
    source = FakeSource.new(10, 100, 1, 1, 1, nil, FakeUser.new(1, "alice"), topic, "Question", {
      "mobile_answer_protocol" => "3"
    }, Time.now)

    assert SorumatikOcr::AnswerGeneration.managed_source?(source)
  end

  def protocol_4_source(age_seconds: 0)
    topic = FakeTopic.new(100, nil, {}, [])
    FakeSource.new(10, 100, 1, 1, 1, nil, FakeUser.new(1, "alice"), topic, "Question", {
      "mobile_answer_protocol" => "4",
      "client_edge_solve" => "true"
    }, Time.now - age_seconds)
  end

  def test_protocol_4_is_client_owned_without_a_lease
    assert SorumatikOcr::AnswerGeneration.client_owned_source?(protocol_4_source)
    assert SorumatikOcr::AnswerGeneration.client_owned_source?(protocol_4_source(age_seconds: 3600))
  end

  def test_protocol_4_is_not_started_by_the_server
    source = protocol_4_source
    refute SorumatikOcr::AnswerGeneration.managed_source?(source)
    error = assert_raises(SorumatikOcr::GeminiAnswerStream::Failure) do
      SorumatikOcr::AnswerGeneration.start!(source)
    end
    assert_equal "client_owned_source", error.code
  end

  def test_protocol_4_without_client_flag_stays_server_owned
    source = protocol_4_source
    source.custom_fields["client_edge_solve"] = "false"
    refute SorumatikOcr::AnswerGeneration.client_owned_source?(source)
  end

  def test_client_heartbeat_timeout_defaults_to_60_seconds
    assert_equal 60, SorumatikOcr::AnswerGeneration.client_heartbeat_timeout
  end

  def test_snapshot_without_persist_publishes_without_writing
    gen = FakeGeneration.new(
      1, "gen-uuid", 100, 10, 1, nil,
      "generating", 3, "", {}, nil, 0,
      nil, "worker-1", Time.now, false, 1,
      Time.now, Time.now, nil
    )
    published = []
    gen.define_singleton_method(:publish!) { published << [raw, sequence] }
    runner = SorumatikOcr::AnswerGeneration.new(gen)

    runner.send(:save_snapshot!, "Kısmi", persist: false)
    runner.send(:save_snapshot!, "Kısmi cevap", persist: true)

    assert_equal [["Kısmi", 4], ["Kısmi cevap", 5]], published
    assert_equal ["Kısmi cevap"], gen.saves
  end

  def test_incomplete_provider_cannot_be_persisted_as_completed
    gen = FakeGeneration.new(
      1, "gen-uuid", 100, 10, 1, nil,
      "persisting", 1, "Partial text...", {}, nil, 0,
      nil, "worker-1", Time.now, false, 1, # provider_completed is FALSE
      Time.now, Time.now, FakeSource.new(10, 100, 1, 1, 1, nil, FakeUser.new(1, "alice"), nil, "Q", {}, Time.now)
    )

    runner = SorumatikOcr::AnswerGeneration.new(gen)
    runner.persist!

    refute_equal "completed", gen.state
    assert_equal "persisting", gen.state
    assert_equal "persistence_failed", gen.error[:code]
  end

  def test_transient_error_retries_up_to_3_attempts
    gen = FakeGeneration.new(
      1, "gen-uuid", 100, 10, 1, nil,
      "queued", 0, "", {}, nil, 0,
      nil, nil, nil, false, 0,
      Time.now, Time.now, FakeSource.new(10, 100, 1, 1, 1, nil, FakeUser.new(1, "alice"), FakeTopic.new(100, nil, {}, []), "Q", {}, Time.now)
    )

    runner = SorumatikOcr::AnswerGeneration.new(gen)
    # Simulate a transient connection failure
    SorumatikOcr::GeminiAnswerStream.stub(:new, ->(*){ raise SorumatikOcr::GeminiAnswerStream::Failure.new("upstream_503") }) do
      runner.run!
    end

    assert_equal "queued", gen.state
    assert_equal 1, gen.attempts
    assert gen.error[:retryable]
    assert_equal :sorumatik_generate_answer, Jobs.enqueued.last[0]
  end

  def test_max_attempts_exceeded_fails
    gen = FakeGeneration.new(
      1, "gen-uuid", 100, 10, 1, nil,
      "queued", 0, "", {}, nil, 0,
      nil, nil, nil, false, 3, # already 3 attempts
      Time.now, Time.now, FakeSource.new(10, 100, 1, 1, 1, nil, FakeUser.new(1, "alice"), FakeTopic.new(100, nil, {}, []), "Q", {}, Time.now)
    )

    runner = SorumatikOcr::AnswerGeneration.new(gen)
    runner.run!

    assert_equal "failed", gen.state
    assert_equal "max_attempts_exceeded", gen.error[:code]
  end
end
