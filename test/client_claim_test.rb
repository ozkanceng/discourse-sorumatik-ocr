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
  def self.gemini_ai_solve_category_ids; ""; end
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

class Jobs
  @enqueued = []
  class << self
    attr_accessor :enqueued
    def enqueue(name, args = {}); @enqueued << [name, args]; end
  end
end

class Post
  def self.types; { regular: 1 }; end
end

module SorumatikOcr
  def self.resolve_api_key; "test-key"; end

  class AiGeneration
    ATTRS = %i[id source_post_id topic_id user_id post_id state sequence raw error
               execution_id heartbeat_at provider_completed content_sha256 metrics].freeze
    attr_accessor(*ATTRS)
    attr_reader :publishes

    @rows = {}
    class << self
      attr_accessor :rows

      def find_by(source_post_id:)
        rows[source_post_id]
      end

      def find_or_create_by!(source_post_id:)
        rows[source_post_id] ||= new(source_post_id).tap { |g| yield g if block_given? }
      end
    end

    def initialize(source_post_id)
      @id = source_post_id
      @source_post_id = source_post_id
      @state = "queued"
      @sequence = 0
      @raw = ""
      @publishes = 0
    end

    def with_lock; yield; end
    def publish!; @publishes += 1; end
    def update!(attrs); attrs.each { |k, v| send("#{k}=", v) }; end
  end
end

require_relative "../lib/sorumatik_ocr/gemini_answer_stream"
require_relative "../lib/sorumatik_ocr/answer_generation"
require_relative "../lib/sorumatik_ocr/proxy_capacity"

class ClientClaimTest < Minitest::Test
  FakeSource = Struct.new(:id, :topic_id, :user_id) do
    def with_lock; yield; end
  end

  TOKEN = "claim-token-0123456789"
  OTHER = "other-token-0123456789"

  def setup
    SorumatikOcr::AiGeneration.rows = {}
    Jobs.enqueued = []
    @source = FakeSource.new(10, 100, 1)
  end

  def generation
    SorumatikOcr::AiGeneration.rows[10]
  end

  def claim(token = TOKEN)
    SorumatikOcr::AnswerGeneration.client_claim!(@source, token)
  end

  def test_claims_queued_generation_without_text
    gen, claimed = claim

    assert claimed
    assert_equal "generating", gen.state
    assert_equal "client-#{TOKEN}", gen.execution_id
    assert_equal 1, gen.publishes
  end

  def test_creates_and_claims_when_server_has_no_generation_yet
    gen, claimed = claim

    assert claimed
    assert_equal 100, gen.topic_id
    assert_equal 1, gen.user_id
  end

  def test_does_not_claim_generation_owned_by_worker
    claim
    generation.execution_id = "worker-uuid"

    _, claimed = claim
    refute claimed
    assert_equal "worker-uuid", generation.execution_id
  end

  def test_does_not_claim_generation_with_text
    SorumatikOcr::AiGeneration.find_or_create_by!(source_post_id: 10)
    generation.raw = "Kısmi cevap"

    _, claimed = claim
    refute claimed
    assert_equal "queued", generation.state
  end

  def test_second_client_cannot_take_over
    claim
    _, claimed = claim(OTHER)

    refute claimed
    assert_equal "client-#{TOKEN}", generation.execution_id
  end

  def test_same_client_reclaim_is_idempotent
    claim
    _, claimed = claim

    assert claimed
    assert_equal "generating", generation.state
  end

  def test_claims_failed_generation_without_text
    SorumatikOcr::AiGeneration.find_or_create_by!(source_post_id: 10)
    generation.state = "failed"
    generation.error = { code: "provider_503" }

    _, claimed = claim
    assert claimed
    assert_nil generation.error
  end

  def test_rejects_invalid_token
    assert_raises(SorumatikOcr::GeminiAnswerStream::Failure) { claim("short") }
  end

  def test_release_requeues_for_worker
    claim
    _, released = SorumatikOcr::AnswerGeneration.client_release!(@source, TOKEN)

    assert released
    assert_equal "queued", generation.state
    assert_nil generation.execution_id
    assert_equal [:sorumatik_generate_answer, { generation_id: 10 }], Jobs.enqueued.last
  end

  def test_release_with_wrong_token_is_ignored
    claim
    _, released = SorumatikOcr::AnswerGeneration.client_release!(@source, OTHER)

    refute released
    assert_equal "generating", generation.state
    assert_empty Jobs.enqueued
  end

  def test_import_rejects_unclaimed_in_progress_generation
    claim
    generation.execution_id = "worker-uuid"

    error = assert_raises(SorumatikOcr::GeminiAnswerStream::Failure) do
      SorumatikOcr::AnswerGeneration.import!(@source, "Cevap", claim_token: TOKEN)
    end
    assert_equal "answer_in_progress", error.code
  end

  def test_import_accepts_claiming_client
    claim
    persisted = []
    runner = Object.new
    runner.define_singleton_method(:persist!) { persisted << true }
    generation.define_singleton_method(:reload) { self }

    SorumatikOcr::AnswerGeneration.stub(:new, ->(_g) { runner }) do
      SorumatikOcr::AnswerGeneration.import!(@source, "Cevap", claim_token: TOKEN)
    end

    assert_equal "persisting", generation.state
    assert_equal "Cevap", generation.raw
    assert_equal [true], persisted
  end
end

class ProxyCapacityTest < Minitest::Test
  class FakeRedis
    def initialize; @set = {}; end
    def zadd(_key, score, member); @set[member] = score; end
    def zrem(_key, member); @set.delete(member); end
    def zcard(_key); @set.size; end
    def zremrangebyscore(_key, _min, max); @set.reject! { |_, s| s <= max }; end
  end

  class BrokenRedis
    def method_missing(*); raise "redis down"; end
    def respond_to_missing?(*); true; end
  end

  def setup
    @redis = FakeRedis.new
  end

  def test_rejects_streams_over_limit
    limit = SorumatikOcr::ProxyCapacity.limit
    slots = Array.new(limit) { SorumatikOcr::ProxyCapacity.acquire(redis: @redis, now: 1000.0) }

    assert slots.all?
    assert_nil SorumatikOcr::ProxyCapacity.acquire(redis: @redis, now: 1000.0)
    refute SorumatikOcr::ProxyCapacity.available?(redis: @redis, now: 1000.0)

    SorumatikOcr::ProxyCapacity.release(slots.first, redis: @redis)
    assert SorumatikOcr::ProxyCapacity.available?(redis: @redis, now: 1000.0)
  end

  def test_slots_of_crashed_workers_expire
    SorumatikOcr::ProxyCapacity.limit.times { SorumatikOcr::ProxyCapacity.acquire(redis: @redis, now: 1000.0) }
    later = 1000.0 + SorumatikOcr::ProxyCapacity::SLOT_TTL_SECONDS + 1

    assert SorumatikOcr::ProxyCapacity.acquire(redis: @redis, now: later)
  end

  def test_redis_failure_fails_open
    assert_equal :untracked, SorumatikOcr::ProxyCapacity.acquire(redis: BrokenRedis.new)
    assert SorumatikOcr::ProxyCapacity.available?(redis: BrokenRedis.new)
  end
end
