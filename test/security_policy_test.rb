# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "securerandom"

class Numeric
  def minutes; self * 60; end unless method_defined?(:minutes)
  def seconds; self; end unless method_defined?(:seconds)
  def megabytes; self * 1024 * 1024; end unless method_defined?(:megabytes)
end

class Time
  def self.current; Time.now; end unless singleton_class.method_defined?(:current)
end

module SiteSetting
  class << self
    attr_accessor :gemini_ai_allowed_models
  end
  def self.gemini_ai_solve_enabled; true; end
  def self.gemini_ai_solve_bot_username; "sorumatik_ai"; end
  def self.gemini_ai_solve_rate_limit_per_minute; 15; end
  def self.gemini_ai_solve_model; "gemini-3.7-flash"; end
  def self.gemini_ai_solve_system_prompt; "Prompt"; end
  def self.sorumatik_ai_generation_streaming_enabled; true; end
  def self.gemini_ai_solve_thinking_level; "default"; end
  def self.gemini_ai_solve_category_ids; ""; end
end unless defined?(SiteSetting)

module SorumatikOcr
  def self.resolve_api_key; "test-key"; end unless singleton_class.method_defined?(:resolve_api_key)
end

class MessageBus
  def self.publish(*_args); true; end
end unless defined?(MessageBus)

class FakeSecLogger
  def info(*); end
  def warn(*); end
  def error(*); end
end

class Rails
  def self.logger
    @logger ||= FakeSecLogger.new
  end
end unless defined?(Rails)

class RateLimiter
  def initialize(*_args); end
  def performed!; true; end
end unless defined?(RateLimiter)

class Jobs
  @enqueued = []
  class << self
    attr_accessor :enqueued
    def enqueue(name, args = {}); @enqueued << [name, args]; end
    def enqueue_in(delay, name, args = {}); @enqueued << [name, args, delay]; end
  end
end unless defined?(Jobs)

class Guardian
  def initialize(*); end
  def can_see?(*); true; end
end unless defined?(Guardian)

class Post
  def self.types; { regular: 1 }; end
end unless defined?(Post)

require_relative "../lib/sorumatik_ocr/security_policy"
require_relative "../lib/sorumatik_ocr/gemini_answer_stream"
require_relative "../lib/sorumatik_ocr/answer_generation"

class SecurityPolicyTest < Minitest::Test
  Policy = SorumatikOcr::SecurityPolicy

  FakeRequest = Struct.new(:request_method, :host, :headers, :env)
  FakeUser = Struct.new(:id, :username, :active, :suspended, :silenced, :staged, :trust_level, :staff) do
    def active?; active.nil? ? true : active; end
    def suspended?; !!suspended; end
    def silenced?; !!silenced; end
    def staff?; !!staff; end
  end
  FakeTopic = Struct.new(:id, :title, :first_post, :custom_fields, :tags, :deleted_at, :visible) do
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
  FakePost = Struct.new(:id, :topic_id, :user_id, :post_number, :post_type, :deleted_at, :hidden, :user, :topic, :raw, :custom_fields, :created_at) do
    def hidden?; !!hidden; end
    def with_lock; yield; end
    def reply_to_post; nil; end
  end
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
    def update_columns(attrs); update!(attrs); end
  end

  def setup
    SiteSetting.gemini_ai_allowed_models = nil if SiteSetting.respond_to?(:gemini_ai_allowed_models=)
    Jobs.enqueued = [] if Jobs.respond_to?(:enqueued=)
  end

  # --- 1. Model Allowlist & Cost/Path-Injection Tests ---

  def test_allows_economic_flash_and_flash_lite_models
    assert_equal "gemini-2.5-flash", Policy.resolve_text_model("gemini-2.5-flash")
    assert_equal "gemini-3.7-flash", Policy.resolve_text_model("gemini-3.7-flash")
    assert_equal "gemini-3.8-flash", Policy.resolve_text_model("gemini-3.8-flash")
    assert_equal "gemini-3.1-flash-lite", Policy.resolve_text_model("gemini-3.1-flash-lite")
  end

  def test_blocks_expensive_pro_argon_imagen_and_path_traversal_models
    assert_equal "gemini-2.5-flash", Policy.resolve_text_model("gemini-3.1-pro", setting_model: "gemini-2.5-flash")
    assert_equal "gemini-2.5-flash", Policy.resolve_text_model("gemini-2.5-pro-preview-05-06", setting_model: "gemini-2.5-flash")
    assert_equal "gemini-2.5-flash", Policy.resolve_text_model("gemini-4-argon", setting_model: "gemini-2.5-flash")
    assert_equal "gemini-2.5-flash", Policy.resolve_text_model("imagen-3.0-generate-002", setting_model: "gemini-2.5-flash")
    assert_equal "gemini-2.5-flash", Policy.resolve_text_model("veo-2.0-generate-001", setting_model: "gemini-2.5-flash")
    assert_equal "gemini-2.5-flash", Policy.resolve_text_model("gemini-2.5-flash/../../files", setting_model: "gemini-2.5-flash")
  end

  def test_custom_site_setting_allowlist_still_blocks_pro_tokens
    setting = Struct.new(:gemini_ai_allowed_models).new("gemini-2.5-flash|gemini-3.1-pro")
    assert_equal "gemini-2.5-flash", Policy.resolve_text_model("gemini-3.1-pro", site_setting: setting)
    assert_equal "gemini-2.5-flash", Policy.resolve_text_model("gemini-3.8-flash", site_setting: setting, fallback: "gemini-2.5-flash")
  end

  def test_tts_model_allowlist_permits_flash_tts_and_blocks_pro
    assert_equal "gemini-3.8-flash-lite-tts", Policy.resolve_tts_model("gemini-3.8-flash-lite-tts")
    assert_equal "gemini-2.5-flash-preview-tts", Policy.resolve_tts_model("gemini-2.5-flash-preview-tts")
    assert_equal "gemini-3.8-flash-lite-tts", Policy.resolve_tts_model("gemini-3.1-pro")
    assert_equal "gemini-3.8-flash-lite-tts", Policy.resolve_tts_model("gemini-2.5-flash")
  end

  # --- 2. Authentication & CSRF Same-Origin Tests ---

  def test_active_user_rejects_nil_suspended_silenced_and_inactive_users
    refute Policy.active_user?(nil)
    refute Policy.active_user?(FakeUser.new(1, "u1", false, false, false, false, 1, false))
    refute Policy.active_user?(FakeUser.new(2, "u2", true, true, false, false, 1, false))
    refute Policy.active_user?(FakeUser.new(3, "u3", true, false, true, false, 1, false))
    refute Policy.active_user?(FakeUser.new(4, "u4", true, false, false, true, 1, false))
    assert Policy.active_user?(FakeUser.new(5, "u5", true, false, false, false, 1, false))
  end

  def test_valid_mobile_client_requires_exact_client_id
    assert Policy.valid_mobile_client?(FakeRequest.new("POST", "sorumatik.co", { "User-Api-Client-Id" => "sorumatik_mobile_v4" }, {}))
    refute Policy.valid_mobile_client?(FakeRequest.new("POST", "sorumatik.co", { "User-Api-Key" => "fake_key_only" }, {}))
    refute Policy.valid_mobile_client?(FakeRequest.new("POST", "sorumatik.co", {}, {}))
  end

  def test_csrf_same_origin_blocks_cross_site_and_null_origins
    user = FakeUser.new(1, "student", true, false, false, false, 1, false)

    evil_origin = FakeRequest.new("POST", "sorumatik.co", { "Origin" => "https://evil.example.com" }, {})
    refute Policy.same_origin_request?(evil_origin, current_user: user)

    null_origin = FakeRequest.new("POST", "sorumatik.co", { "Origin" => "null" }, {})
    refute Policy.same_origin_request?(null_origin, current_user: user)

    bare_cookie_post = FakeRequest.new("POST", "sorumatik.co", {}, {})
    refute Policy.same_origin_request?(bare_cookie_post, current_user: user)
  end

  def test_csrf_same_origin_allows_valid_web_origin_and_mobile_api_key
    user = FakeUser.new(1, "student", true, false, false, false, 1, false)

    web_origin = FakeRequest.new("POST", "sorumatik.co", { "Origin" => "https://sorumatik.co" }, {})
    assert Policy.same_origin_request?(web_origin, current_user: user)

    en_origin = FakeRequest.new("POST", "en.sorumatik.co", { "Origin" => "https://en.sorumatik.co" }, {})
    assert Policy.same_origin_request?(en_origin, current_user: user)

    mobile_api = FakeRequest.new("POST", "sorumatik.co", { "User-Api-Key" => "verified_discourse_token" }, {})
    assert Policy.same_origin_request?(mobile_api, current_user: user)

    guest_mobile = FakeRequest.new("POST", "sorumatik.co", { "User-Api-Client-Id" => "sorumatik_mobile_v4" }, {})
    assert Policy.same_origin_request?(guest_mobile, current_user: nil)
  end

  # --- 3. SSRF & Private/Metadata IP Shield Tests ---

  def test_private_or_reserved_ip_blocks_loopback_rfc1918_metadata_and_ipv6_mapped
    assert Policy.private_or_reserved_ip?("127.0.0.1")
    assert Policy.private_or_reserved_ip?("10.0.0.5")
    assert Policy.private_or_reserved_ip?("172.16.10.2")
    assert Policy.private_or_reserved_ip?("172.31.255.1")
    assert Policy.private_or_reserved_ip?("192.168.1.10")
    assert Policy.private_or_reserved_ip?("169.254.169.254")
    assert Policy.private_or_reserved_ip?("100.64.1.1")
    assert Policy.private_or_reserved_ip?("0.0.0.0")
    assert Policy.private_or_reserved_ip?("::1")
    assert Policy.private_or_reserved_ip?("fc00::1")
    assert Policy.private_or_reserved_ip?("fe80::1")
    assert Policy.private_or_reserved_ip?("::ffff:169.254.169.254")
    assert Policy.private_or_reserved_ip?("::ffff:127.0.0.1")

    refute Policy.private_or_reserved_ip?("104.21.45.12")
    refute Policy.private_or_reserved_ip?("2606:4700:3030::6815:1010")
  end

  def test_safe_image_uri_blocks_external_hosts_and_dns_rebinding
    public_dns = Object.new
    public_dns.define_singleton_method(:getaddresses) { |_host| ["104.21.45.12"] }

    rebind_metadata_dns = Object.new
    rebind_metadata_dns.define_singleton_method(:getaddresses) { |_host| ["169.254.169.254"] }

    assert Policy.safe_image_uri?("https://sorumatik.co/uploads/default/original/1X/abc.jpeg", dns_resolver: public_dns)
    assert Policy.safe_image_uri?("https://en.sorumatik.co/uploads/default/original/1X/abc.png", dns_resolver: public_dns)

    refute Policy.safe_image_uri?("http://169.254.169.254/latest/meta-data/iam.png", dns_resolver: public_dns)
    refute Policy.safe_image_uri?("http://127.0.0.1:6379/redis.png", dns_resolver: public_dns)
    refute Policy.safe_image_uri?("https://attacker.example.com/bomb.png", dns_resolver: public_dns)
    refute Policy.safe_image_uri?("file:///etc/passwd", dns_resolver: public_dns)
    refute Policy.safe_image_uri?("https://user:pass@sorumatik.co/uploads/a.png", dns_resolver: public_dns)
    refute Policy.safe_image_uri?("https://sorumatik.co/uploads/rebind.png", dns_resolver: rebind_metadata_dns)
  end

  def test_fetch_safe_image_bytes_enforces_streaming_byte_cap_and_rejects_redirects
    public_dns = Object.new
    public_dns.define_singleton_method(:getaddresses) { |_host| ["104.21.45.12"] }

    oversized_response = Net::HTTPOK.new("1.1", "200", "OK")
    oversized_response.define_singleton_method(:[]) { |_| nil }
    oversized_response.define_singleton_method(:read_body) do |&blk|
      blk.call("A" * 600)
      blk.call("B" * 600)
    end

    fake_http = Object.new
    fake_http.define_singleton_method(:request) { |_req, &blk| blk.call(oversized_response) }

    Net::HTTP.stub(:start, ->(*_args, &blk) { blk.call(fake_http) }) do
      result = Policy.fetch_safe_image_bytes(
        "https://sorumatik.co/uploads/default/huge.png",
        max_bytes: 1000,
        dns_resolver: public_dns
      )
      assert_nil result
    end

    redirect_response = Net::HTTPFound.new("1.1", "302", "Found")
    fake_redirect_http = Object.new
    fake_redirect_http.define_singleton_method(:request) { |_req, &blk| blk.call(redirect_response) }

    Net::HTTP.stub(:start, ->(*_args, &blk) { blk.call(fake_redirect_http) }) do
      result = Policy.fetch_safe_image_bytes(
        "https://sorumatik.co/uploads/default/redir.png",
        max_bytes: 1000,
        dns_resolver: public_dns
      )
      assert_nil result
    end
  end

  # --- 4. Anti-Spam & Retry Amplification Tests ---

  def test_spam_filter_blocks_occult_whatsapp_hidden_and_link_flood_posts
    active_tl0 = FakeUser.new(10, "newbie", true, false, false, false, 0, false)
    suspended_user = FakeUser.new(11, "banned", true, true, false, false, 1, false)

    occult_topic = FakeTopic.new(1, "+2347036230889 Become A Bonafide Member Of The Great Legion Occult Society For Riches And Powers", nil, {}, [], nil, true)
    occult_post = FakePost.new(1, 1, 10, 1, 1, nil, false, active_tl0, occult_topic, "Call or WhatsApp +2347036230889 for spiritual solutions", { "mobile_answer_protocol" => "3" }, Time.now)
    assert Policy.spam_or_ineligible_post?(occult_post)
    refute SorumatikOcr::AnswerGeneration.managed_source?(occult_post)

    hidden_topic = FakeTopic.new(2, "Soru", nil, {}, [], nil, true)
    hidden_post = FakePost.new(2, 2, 10, 1, 1, nil, true, active_tl0, hidden_topic, "Normal metin ama moderasyon gizledi", {}, Time.now)
    assert Policy.spam_or_ineligible_post?(hidden_post)

    suspended_post = FakePost.new(3, 2, 11, 1, 1, nil, false, suspended_user, hidden_topic, "2x + 4 = 10 ise x kaçtır?", {}, Time.now)
    assert Policy.spam_or_ineligible_post?(suspended_post)

    link_flood_post = FakePost.new(
      4, 2, 10, 1, 1, nil, false, active_tl0, hidden_topic,
      "Check https://spam1.example.org https://spam2.example.org https://spam3.example.org",
      {}, Time.now
    )
    assert Policy.spam_or_ineligible_post?(link_flood_post)
  end

  def test_spam_filter_allows_legitimate_turkish_and_english_exam_questions
    student = FakeUser.new(20, "ogrenci", true, false, false, false, 0, false)
    topic = FakeTopic.new(50, "TYT Matematik Fonksiyon Sorusu", nil, {}, [], nil, true)
    post = FakePost.new(
      50, 50, 20, 1, 1, nil, false, student, topic,
      "$f(x) = x^2 + 234$ fonksiyonu veriliyor. ![soru](https://sorumatik.co/uploads/default/1.jpg) Buna göre $f(2)$ kaçtır?",
      { "mobile_answer_protocol" => "3" }, Time.now
    )

    refute Policy.spam_or_ineligible_post?(post)
    assert SorumatikOcr::AnswerGeneration.managed_source?(post)
  end

  def test_generation_timeout_is_not_retried
    student = FakeUser.new(20, "ogrenci", true, false, false, false, 1, false)
    topic = FakeTopic.new(60, "İntegral Sorusu", nil, {}, [], nil, true)
    source = FakePost.new(60, 60, 20, 1, 1, nil, false, student, topic, "İntegral sorusu", {}, Time.now)
    gen = FakeGeneration.new(
      1, "gen-timeout-1", 60, 60, 20, nil,
      "queued", 0, "", {}, nil, 0,
      nil, nil, nil, false, 0,
      Time.now, Time.now, source
    )

    runner = SorumatikOcr::AnswerGeneration.new(gen)
    SorumatikOcr::GeminiAnswerStream.stub(:new, ->(*) { raise SorumatikOcr::GeminiAnswerStream::Failure.new("generation_timeout") }) do
      runner.run!
    end

    assert_equal "failed", gen.state
    assert_equal false, gen.error[:retryable]
    assert_empty Jobs.enqueued
  end

  def test_fallback_start_does_not_requeue_non_retryable_failed_generation
    student = FakeUser.new(20, "ogrenci", true, false, false, false, 1, false)
    topic = FakeTopic.new(61, "Limit Sorusu", nil, {}, [], nil, true)
    source = FakePost.new(61, 61, 20, 1, 1, nil, false, student, topic, "Limit sorusu", {}, Time.now)
    failed_gen = FakeGeneration.new(
      2, "gen-non-retryable", 61, 61, 20, nil,
      "failed", 2, "", {}, { "code" => "generation_timeout", "retryable" => false }, 0,
      nil, nil, nil, false, 1,
      Time.now, Time.now, source
    )

    ai_gen_stub = Class.new do
      define_singleton_method(:exists?) { |**| true }
      define_singleton_method(:find_or_create_by!) { |**| failed_gen }
    end

    had_const = SorumatikOcr.const_defined?(:AiGeneration, false)
    prev_const = SorumatikOcr.const_get(:AiGeneration) if had_const
    SorumatikOcr.send(:remove_const, :AiGeneration) if had_const
    SorumatikOcr.const_set(:AiGeneration, ai_gen_stub)
    begin
      result = SorumatikOcr::AnswerGeneration.start!(source, fallback: true)
      assert_equal "failed", result.state
      assert_empty Jobs.enqueued
    ensure
      SorumatikOcr.send(:remove_const, :AiGeneration)
      SorumatikOcr.const_set(:AiGeneration, prev_const) if had_const
    end
  end
end
