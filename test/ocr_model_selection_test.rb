# frozen_string_literal: true
require "minitest/autorun"
require_relative "../lib/sorumatik_ocr/security_policy"

class OcrModelSelectionTest < Minitest::Test
  class MockSiteSetting
    attr_accessor :gemini_ocr_model, :gemini_ai_allowed_models
  end

  def resolve_ocr_model(site_setting, params = {})
    requested_model = params[:model] || params[:engine]
    SorumatikOcr::SecurityPolicy.resolve_ocr_model(
      requested_model,
      site_setting: site_setting,
      fallback: "gemini-2.5-flash-lite"
    )
  end

  def setup
    @site_setting = MockSiteSetting.new
  end

  def test_defaults_to_flash_lite_when_setting_is_nil
    @site_setting.gemini_ocr_model = nil
    model = resolve_ocr_model(@site_setting)
    assert_equal "gemini-2.5-flash-lite", model
  end

  def test_defaults_to_flash_lite_when_setting_is_empty
    @site_setting.gemini_ocr_model = ""
    model = resolve_ocr_model(@site_setting)
    assert_equal "gemini-2.5-flash-lite", model
  end

  def test_uses_site_setting_when_configured
    @site_setting.gemini_ocr_model = "gemini-2.5-flash"
    model = resolve_ocr_model(@site_setting)
    assert_equal "gemini-2.5-flash", model
  end

  def test_client_param_overrides_site_setting_when_valid_flash_lite
    @site_setting.gemini_ocr_model = "gemini-2.5-flash-lite"
    model = resolve_ocr_model(@site_setting, { model: "gemini-2.0-flash-lite" })
    assert_equal "gemini-2.0-flash-lite", model
  end

  def test_blocks_expensive_pro_model_override_and_falls_back_to_setting
    @site_setting.gemini_ocr_model = "gemini-2.5-flash-lite"
    model = resolve_ocr_model(@site_setting, { engine: "gemini-2.5-pro" })
    assert_equal "gemini-2.5-flash-lite", model
  end

  def test_ignores_generic_gemini_engine_flag_from_mobile_client
    @site_setting.gemini_ocr_model = "gemini-2.5-flash-lite"
    model = resolve_ocr_model(@site_setting, { engine: "gemini" })
    assert_equal "gemini-2.5-flash-lite", model
  end

  def test_invalid_client_param_falls_back_safely_to_setting
    @site_setting.gemini_ocr_model = "gemini-2.5-flash"
    model = resolve_ocr_model(@site_setting, { model: "malicious/path?injection=true" })
    assert_equal "gemini-2.5-flash", model
  end
end
