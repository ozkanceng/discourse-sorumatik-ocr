# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "yaml"

# Kara Tahta v5 server pieces: rollout flags, structured-output schema
# forwarding and the TTS login switch. Loads the real controllers against
# minimal Discourse stand-ins (same approach as ai_config_limits_test.rb).
unless Object.method_defined?(:present?)
  Object.class_eval do
    def blank?
      respond_to?(:empty?) ? !!empty? : !self
    end
    def present?
      !blank?
    end
    def presence
      present? ? self : nil
    end
  end
end

class Numeric
  def minute; self * 60; end unless method_defined?(:minute)
end

module ActionController
  module Live; end
end unless defined?(ActionController::Live)

class ApplicationController
  def self.requires_plugin(*); end
  def self.skip_before_action(*); end
end unless defined?(ApplicationController)

class RateLimiter
  class LimitExceeded < StandardError; end
  def initialize(*_args); end
  def performed!; true; end
end unless defined?(RateLimiter)

class Rails
  class NullLogger
    def info(*); end
    def warn(*); end
    def error(*); end
  end
  def self.logger
    @logger ||= NullLogger.new
  end
end unless defined?(Rails)

module I18n
  def self.t(key, default: nil, **)
    default || key.to_s
  end
end unless defined?(I18n)

module SiteSetting
  class << self
    attr_accessor :sorumatik_client_generation_enabled, :sorumatik_mobile_gemini_api_key,
                  :gemini_ai_solve_bot_username, :gemini_tts_require_login,
                  :sorumatik_blackboard_beta_usernames,
                  :sorumatik_blackboard_engine_v5_percent, :sorumatik_blackboard_generation_v5_percent,
                  :sorumatik_blackboard_segment_tts_percent, :sorumatik_blackboard_export_v2_percent,
                  :sorumatik_blackboard_verify_answers_percent, :sorumatik_blackboard_server_quota_percent
  end
end

module SorumatikOcr
  PLUGIN_NAME = "discourse-sorumatik-ocr" unless const_defined?(:PLUGIN_NAME)
  def self.resolve_mobile_api_key
    SiteSetting.sorumatik_mobile_gemini_api_key.to_s.strip
  end unless singleton_class.method_defined?(:resolve_mobile_api_key)
end

require_relative "../lib/sorumatik_ocr/security_policy"
require_relative "../lib/sorumatik_ocr/answer_generation"
require_relative "../lib/sorumatik_ocr/blackboard_flags"
require_relative "../lib/sorumatik_ocr/response_schema"
require_relative "../app/controllers/sorumatik_ocr/ai_controller"
require_relative "../app/controllers/sorumatik_ocr/ai_config_controller"

class BlackboardV5ServerTest < Minitest::Test
  FakeUser = Struct.new(:id, :username) do
    def active?; true; end
  end
  FakeRequest = Struct.new(:remote_ip, :headers)
  Flags = SorumatikOcr::BlackboardFlags

  def setup
    SiteSetting.sorumatik_client_generation_enabled = false
    SiteSetting.sorumatik_mobile_gemini_api_key = ""
    SiteSetting.gemini_ai_solve_bot_username = "sorumatik_ai"
    SiteSetting.gemini_tts_require_login = false
    SiteSetting.sorumatik_blackboard_beta_usernames = ""
    Flags::KEYS.each { |key| SiteSetting.public_send(:"sorumatik_blackboard_#{key}_percent=", 0) }
  end

  # --- flags -------------------------------------------------------------

  def test_every_flag_is_off_by_default
    flags = Flags.for_user(FakeUser.new(7, "ayse"))
    assert_equal Flags::KEYS.sort, flags.keys.sort
    assert(flags.values.none?)
  end

  def test_hundred_percent_reaches_anonymous_requests_too
    SiteSetting.sorumatik_blackboard_engine_v5_percent = 100
    assert_equal true, Flags.for_user(nil)["engine_v5"]
    assert_equal false, Flags.for_user(nil)["export_v2"]
  end

  def test_partial_rollout_is_stable_and_grows_monotonically
    users = (1..2_000).map { |id| FakeUser.new(id, "u#{id}") }
    SiteSetting.sorumatik_blackboard_engine_v5_percent = 10
    at10 = users.select { |u| Flags.for_user(u)["engine_v5"] }
    assert_equal at10, users.select { |u| Flags.for_user(u)["engine_v5"] }, "same users on every request"
    assert_in_delta 200, at10.size, 60
    SiteSetting.sorumatik_blackboard_engine_v5_percent = 50
    at50 = users.select { |u| Flags.for_user(u)["engine_v5"] }
    assert_empty at10 - at50, "raising the percentage never removes a user"
    assert_equal false, Flags.for_user(nil)["engine_v5"], "anonymous only at 100%"
  end

  def test_flags_use_independent_buckets
    users = (1..2_000).map { |id| FakeUser.new(id, "u#{id}") }
    SiteSetting.sorumatik_blackboard_engine_v5_percent = 50
    SiteSetting.sorumatik_blackboard_export_v2_percent = 50
    same = users.count { |u| Flags.for_user(u).values_at("engine_v5", "export_v2").uniq.size == 1 }
    assert_operator same, :<, 1_400
  end

  def test_beta_usernames_get_every_flag
    SiteSetting.sorumatik_blackboard_beta_usernames = "Dersnotu|qa_user"
    assert(Flags.for_user(FakeUser.new(3, "dersnotu")).values.all?)
    assert(Flags.for_user(FakeUser.new(4, "other")).values.none?)
  end

  def test_ai_config_carries_the_flags_and_never_a_key
    SiteSetting.sorumatik_blackboard_server_quota_percent = 100
    controller = Class.new(SorumatikOcr::AiConfigController) do
      attr_accessor :current_user
      attr_reader :rendered
      def request
        BlackboardV5ServerTest::FakeRequest.new("127.0.0.1", {})
      end
      def render(json:, status: 200)
        (@rendered = { json: json, status: status })
      end
    end.new
    controller.current_user = FakeUser.new(1, "ayse")
    controller.show
    json = controller.rendered[:json]
    assert_equal true, json[:blackboard_flags]["server_quota"]
    assert_equal false, json[:blackboard_flags]["engine_v5"]
    assert_equal "", json[:api_key]
  end

  def test_every_flag_has_a_percent_setting_and_locale_text
    settings = YAML.load_file(File.expand_path("../config/settings.yml", __dir__))["plugins"]
    en = YAML.load_file(File.expand_path("../config/locales/server.en.yml", __dir__))["en"]["site_settings"]
    Flags::KEYS.each do |key|
      name = "sorumatik_blackboard_#{key}_percent"
      assert_equal 0, settings.fetch(name)["default"], name
      assert en.key?(name), "#{name} needs an admin description"
    end
    assert_equal false, settings.fetch("gemini_tts_require_login")["default"]
  end

  # --- structured output ---------------------------------------------------

  def test_schema_keeps_supported_keywords_only
    schema = SorumatikOcr::ResponseSchema.sanitize(
      "type" => "object",
      "required" => ["steps"],
      "properties" => {
        "id" => { "type" => "string", "pattern" => "^seg_\\d+$", "minLength" => 3 },
        "steps" => { "type" => "array", "minItems" => 3, "items" => { "$ref" => "#/$defs/Step" } },
      },
      "$defs" => { "Step" => { "type" => "object", "properties" => { "n" => { "type" => "integer", "maximum" => 9 } } } },
    )
    assert_equal({ "type" => "string" }, schema["properties"]["id"])
    assert_equal 3, schema["properties"]["steps"]["minItems"]
    assert_equal 9, schema["$defs"]["Step"]["properties"]["n"]["maximum"]
  end

  def test_schema_accepts_a_json_string_and_rejects_bad_input
    assert_equal({ "type" => "object" }, SorumatikOcr::ResponseSchema.sanitize('{"type":"object"}'))
    assert_nil SorumatikOcr::ResponseSchema.sanitize(nil)
    assert_raises(SorumatikOcr::ResponseSchema::Invalid) { SorumatikOcr::ResponseSchema.sanitize("[1]") }
    assert_raises(SorumatikOcr::ResponseSchema::Invalid) { SorumatikOcr::ResponseSchema.sanitize("{oops") }
    big = { "type" => "object", "description" => "x" * 40_000 }
    assert_raises(SorumatikOcr::ResponseSchema::Invalid) { SorumatikOcr::ResponseSchema.sanitize(big) }
    deep = { "type" => "object" }
    30.times { deep = { "type" => "object", "properties" => { "a" => deep } } }
    assert_raises(SorumatikOcr::ResponseSchema::Invalid) { SorumatikOcr::ResponseSchema.sanitize(deep) }
  end

  class CapturingAiController < SorumatikOcr::AiController
    attr_accessor :params, :current_user
    attr_reader :rendered, :sent_payload

    def request
      BlackboardV5ServerTest::FakeRequest.new("127.0.0.1", {})
    end
    def render(json:, status: 200)
      (@rendered = { json: json, status: status })
    end
    def render_json_error(message, status:)
      (@rendered = { json: { error: message }, status: status })
    end
    def ensure_authenticated_user!
      true
    end
    def ensure_plugin_and_key!
      true
    end
    def enforce_rate_limit!
      true
    end
    def resolve_api_key
      "server-key"
    end

    def call_gemini_sync(_model, _key, payload)
      @sent_payload = payload
      { success: true, text: "{}" }
    end
  end

  def generate(params)
    controller = CapturingAiController.new
    controller.params = params
    controller.current_user = FakeUser.new(1, "ayse")
    controller.generate
    controller
  end

  def test_generate_forwards_the_schema_for_json_requests
    c = generate(prompt: "Çöz", is_json: "true", response_schema: { "type" => "object", "pattern" => "x" })
    config = c.sent_payload[:generationConfig]
    assert_equal "application/json", config[:responseMimeType]
    assert_equal({ "type" => "object" }, config[:responseJsonSchema])
  end

  def test_generate_ignores_the_schema_for_text_requests
    c = generate(prompt: "Çöz", response_schema: { "type" => "object" })
    refute c.sent_payload[:generationConfig].key?(:responseJsonSchema)
  end

  def test_generate_rejects_an_invalid_schema
    c = generate(prompt: "Çöz", is_json: "true", response_schema: "{nope")
    assert_equal 400, c.rendered[:status]
    assert_nil c.sent_payload
  end

  # --- TTS login switch ----------------------------------------------------

  class TtsAuthController < SorumatikOcr::AiController
    attr_accessor :current_user, :client_id
    attr_reader :rendered
    def request
      BlackboardV5ServerTest::FakeRequest.new("127.0.0.1", { "User-Api-Client-Id" => client_id })
    end
    def render_json_error(message, status:)
      (@rendered = { error: message, status: status })
    end
    def ensure_same_origin!
      true
    end
    def check!
      ensure_tts_authorized!
    end
  end

  def tts_auth(user:, client_id:)
    c = TtsAuthController.new
    c.current_user = user
    c.client_id = client_id
    [c.check!, c.rendered]
  end

  def test_tts_login_switch
    mobile = SorumatikOcr::SecurityPolicy::MOBILE_CLIENT_ID
    assert_equal true, tts_auth(user: nil, client_id: mobile).first, "old app builds keep working while the switch is off"
    SiteSetting.gemini_tts_require_login = true
    ok, rendered = tts_auth(user: nil, client_id: mobile)
    assert_equal false, ok
    assert_equal 401, rendered[:status]
    assert_equal true, tts_auth(user: FakeUser.new(1, "ayse"), client_id: mobile).first
  end
end
