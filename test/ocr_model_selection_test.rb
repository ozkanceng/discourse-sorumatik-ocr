# frozen_string_literal: true
require "minitest/autorun"

class OcrModelSelectionTest < Minitest::Test
  class MockSiteSetting
    attr_accessor :gemini_ocr_model
  end

  def resolve_ocr_model(site_setting, params = {})
    requested_model = (params[:model] || params[:engine]).to_s.strip
    if requested_model.present? && requested_model =~ /\Agemini-[a-zA-Z0-9.-]+\z/
      requested_model
    else
      site_setting.gemini_ocr_model.presence || "gemini-2.5-flash-lite"
    end
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

  def test_client_param_overrides_site_setting_when_valid
    @site_setting.gemini_ocr_model = "gemini-2.5-flash-lite"
    model = resolve_ocr_model(@site_setting, { model: "gemini-2.0-flash-lite" })
    assert_equal "gemini-2.0-flash-lite", model
  end

  def test_client_param_engine_overrides_when_valid
    @site_setting.gemini_ocr_model = "gemini-2.5-flash-lite"
    model = resolve_ocr_model(@site_setting, { engine: "gemini-2.5-pro" })
    assert_equal "gemini-2.5-pro", model
  end

  def test_invalid_client_param_falls_back_safely_to_setting
    @site_setting.gemini_ocr_model = "gemini-2.5-flash"
    model = resolve_ocr_model(@site_setting, { model: "malicious/path?injection=true" })
    assert_equal "gemini-2.5-flash", model
  end
end
