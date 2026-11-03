# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

# Loads the real controllers against minimal Discourse stand-ins.
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

class FakeConfigLogger
  def info(*); end
  def warn(*); end
  def error(*); end
end

class Rails
  def self.logger
    @logger ||= FakeConfigLogger.new
  end
end unless defined?(Rails)

module SiteSetting
  class << self
    attr_accessor :gemini_ai_solve_bot_username
  end
end unless defined?(SiteSetting)

module SorumatikOcr
  PLUGIN_NAME = "discourse-sorumatik-ocr" unless const_defined?(:PLUGIN_NAME)
end

require_relative "../lib/sorumatik_ocr/security_policy"
require_relative "../lib/sorumatik_ocr/answer_generation"
require_relative "../lib/sorumatik_ocr/blackboard_flags"
require_relative "../app/controllers/sorumatik_ocr/ai_controller"
require_relative "../app/controllers/sorumatik_ocr/ai_config_controller"

class AiConfigLimitsTest < Minitest::Test
  FakeRequest = Struct.new(:remote_ip)
  FakeUser = Struct.new(:id) do
    def active?; true; end
  end

  class TestConfigController < SorumatikOcr::AiConfigController
    attr_accessor :current_user
    attr_reader :rendered

    def request
      FakeRequest.new("127.0.0.1")
    end

    def render(json:, status: 200)
      @rendered = { json: json, status: status }
    end
  end

  def setup
    SiteSetting.gemini_ai_solve_bot_username = "sorumatik_ai"
  end

  def config_json(user: FakeUser.new(1))
    controller = TestConfigController.new
    controller.current_user = user
    controller.show
    assert_equal 200, controller.rendered[:status]
    json = controller.rendered[:json]
    assert_equal true, json[:success]
    json
  end

  def test_proxy_limits
    assert_equal 60_000, SorumatikOcr::AiController::MAX_PROMPT_CHARS
    assert_equal 10_000, SorumatikOcr::AiController::MAX_SYSTEM_INSTRUCTION_CHARS
    assert_equal 2_500, SorumatikOcr::AiController::MAX_TTS_TEXT_CHARS
  end

  def test_config_exposes_proxy_limits
    json = config_json
    assert_equal 60_000, json[:max_prompt_chars]
    assert_equal 10_000, json[:max_system_instruction_chars]
    assert_equal 2_500, json[:max_tts_text_chars]
  end

  def test_config_exposes_limits_to_anonymous_requests
    json = config_json(user: nil)
    assert_equal 60_000, json[:max_prompt_chars]
    assert_equal "", json[:api_key]
  end

  def test_signed_in_user_never_gets_a_key
    json = config_json
    assert_equal "", json[:api_key]
    assert_equal 3, json[:mobile_answer_protocol]
    assert_equal false, json[:client_generation]
    assert_equal true, json[:server_generation]
    assert_equal "proxy_only", json[:client_generation_blocked]
  end

  def test_settings_have_no_device_key
    settings = YAML.load_file(File.expand_path("../config/settings.yml", __dir__))
    names = settings.values.flat_map { |group| group.is_a?(Hash) ? group.keys : [] }
    refute_includes names, "sorumatik_mobile_gemini_api_key"
    refute_includes names, "gemini_legacy_client_fallback"
    refute_includes names, "sorumatik_client_generation_enabled"
  end
end
