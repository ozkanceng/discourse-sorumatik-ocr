# frozen_string_literal: true
require "minitest/autorun"

class ApiKeyResolutionTest < Minitest::Test
  class MockSiteSetting
    attr_accessor :sorumatik_ocr_api_key, :gemini_ocr_api_key, :blackboard_gemini_api_key

    def respond_to?(method_name, include_all = false)
      [:sorumatik_ocr_api_key, :gemini_ocr_api_key, :blackboard_gemini_api_key].include?(method_name.to_sym) || super
    end
  end

  def resolve_api_key(site_setting, env = {})
    key = (site_setting.respond_to?(:sorumatik_ocr_api_key) && site_setting.sorumatik_ocr_api_key.presence) ||
          (site_setting.respond_to?(:gemini_ocr_api_key) && site_setting.gemini_ocr_api_key.presence) ||
          (site_setting.respond_to?(:blackboard_gemini_api_key) && site_setting.blackboard_gemini_api_key.presence) ||
          env["GEMINI_API_KEY"] ||
          env["DISCOURSE_GEMINI_OCR_API_KEY"]
    key.to_s.strip
  end

  def setup
    @site_setting = MockSiteSetting.new
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
  end

  def test_prefers_sorumatik_ocr_api_key
    @site_setting.sorumatik_ocr_api_key = "AIzaSy_sorumatik_key"
    @site_setting.gemini_ocr_api_key = "AIzaSy_gemini_key"
    assert_equal "AIzaSy_sorumatik_key", resolve_api_key(@site_setting)
  end

  def test_falls_back_to_gemini_ocr_api_key
    @site_setting.sorumatik_ocr_api_key = ""
    @site_setting.gemini_ocr_api_key = "AIzaSy_gemini_key"
    assert_equal "AIzaSy_gemini_key", resolve_api_key(@site_setting)
  end

  def test_falls_back_to_blackboard_gemini_api_key
    @site_setting.sorumatik_ocr_api_key = nil
    @site_setting.gemini_ocr_api_key = nil
    @site_setting.blackboard_gemini_api_key = "AIzaSy_blackboard_key"
    assert_equal "AIzaSy_blackboard_key", resolve_api_key(@site_setting)
  end

  def test_falls_back_to_env_gemini_api_key
    @site_setting.sorumatik_ocr_api_key = nil
    @site_setting.gemini_ocr_api_key = nil
    @site_setting.blackboard_gemini_api_key = nil
    env = { "GEMINI_API_KEY" => "AIzaSy_env_key" }
    assert_equal "AIzaSy_env_key", resolve_api_key(@site_setting, env)
  end

  def test_falls_back_to_env_discourse_gemini_ocr_api_key
    @site_setting.sorumatik_ocr_api_key = nil
    @site_setting.gemini_ocr_api_key = nil
    @site_setting.blackboard_gemini_api_key = nil
    env = { "DISCOURSE_GEMINI_OCR_API_KEY" => "AIzaSy_discourse_env_key" }
    assert_equal "AIzaSy_discourse_env_key", resolve_api_key(@site_setting, env)
  end

  def test_trims_whitespace_from_keys
    @site_setting.gemini_ocr_api_key = "  AIzaSy_padded_key \n\t "
    assert_equal "AIzaSy_padded_key", resolve_api_key(@site_setting)
  end

  def test_returns_empty_when_all_blank
    @site_setting.sorumatik_ocr_api_key = ""
    @site_setting.gemini_ocr_api_key = "   "
    @site_setting.blackboard_gemini_api_key = nil
    assert_equal "", resolve_api_key(@site_setting)
  end
end
