# frozen_string_literal: true
require "minitest/autorun"
require "yaml"
require_relative "../lib/sorumatik_ocr/answer_generation"
require_relative "../lib/sorumatik_ocr/security_policy"

class ThinkingConfigTest < Minitest::Test
  ALLOWED_THINKING_LEVELS = %w[default minimal low medium high].freeze

  def apply_thinking_config(generation_config, model, raw_level)
    level = ALLOWED_THINKING_LEVELS.include?(raw_level) ? raw_level : "default"

    if model.to_s.start_with?("gemini-2.5")
      return if level == "default"
      budget = case level
               when "minimal" then 0
               when "low" then 1024
               when "medium" then 2048
               else 4096
               end
      generation_config[:thinkingConfig] = { thinkingBudget: budget }
    elsif model.to_s.start_with?("gemini-3")
      return if level == "default"
      effective_level = level
      if effective_level == "minimal" && model.to_s.match?(/gemini-3\.(?:[78]|1)/)
        effective_level = "low"
      end
      generation_config[:thinkingConfig] = { thinkingLevel: effective_level }
    end
  end

  def resolve_proxy_max_output_tokens(model, is_json: false, thinking_level: "default")
    m = model.to_s.strip.downcase
    lvl = ALLOWED_THINKING_LEVELS.include?(thinking_level.to_s.strip.downcase) ? thinking_level.to_s.strip.downcase : "default"
    if m.start_with?("gemini-2.5", "gemini-3")
      if %w[minimal low].include?(lvl)
        is_json ? 16_384 : 12_288
      else
        32_768
      end
    else
      is_json ? 8_192 : 4_096
    end
  end

  def test_gemini_3_default_thinking_omits_thinking_config
    gen_config = { maxOutputTokens: 32_768 }
    apply_thinking_config(gen_config, "gemini-3.7-flash", "default")
    assert_nil gen_config[:thinkingConfig], "When level is 'default', thinkingConfig must not be set so model uses native default thinking"
  end

  def test_gemini_3_low_thinking
    gen_config = { maxOutputTokens: 12_288 }
    apply_thinking_config(gen_config, "gemini-3.7-flash", "low")
    assert_equal({ thinkingLevel: "low" }, gen_config[:thinkingConfig])
  end

  def test_gemini_3_medium_thinking
    gen_config = { maxOutputTokens: 32_768 }
    apply_thinking_config(gen_config, "gemini-3.7-flash", "medium")
    assert_equal({ thinkingLevel: "medium" }, gen_config[:thinkingConfig])
  end

  def test_gemini_3_high_thinking
    gen_config = { maxOutputTokens: 32_768 }
    apply_thinking_config(gen_config, "gemini-3.7-flash", "high")
    assert_equal({ thinkingLevel: "high" }, gen_config[:thinkingConfig])
  end

  def test_gemini_37_minimal_thinking_fallbacks_to_low
    gen_config = { maxOutputTokens: 12_288 }
    apply_thinking_config(gen_config, "gemini-3.7-flash", "minimal")
    assert_equal({ thinkingLevel: "low" }, gen_config[:thinkingConfig], "gemini-3.7 minimal should fallback to low")
  end

  def test_gemini_25_default_thinking_omits_thinking_config
    gen_config = { maxOutputTokens: 32_768 }
    apply_thinking_config(gen_config, "gemini-2.5-flash", "default")
    assert_nil gen_config[:thinkingConfig]
  end

  def test_gemini_25_low_thinking_sets_budget
    gen_config = { maxOutputTokens: 12_288 }
    apply_thinking_config(gen_config, "gemini-2.5-flash", "low")
    assert_equal({ thinkingBudget: 1024 }, gen_config[:thinkingConfig])
  end

  def test_answer_generation_olympiad_timeout_and_max_output_tokens
    assert_equal 180, SorumatikOcr::AnswerGeneration::MAX_SECONDS
    assert_equal 90, SorumatikOcr::AnswerGeneration::CLIENT_LEASE_SECONDS

    assert_equal 32_768, SorumatikOcr::AnswerGeneration.resolve_solve_max_output_tokens("gemini-3.7-flash", "default")
    assert_equal 32_768, SorumatikOcr::AnswerGeneration.resolve_solve_max_output_tokens("gemini-3.7-flash", "medium")
    assert_equal 32_768, SorumatikOcr::AnswerGeneration.resolve_solve_max_output_tokens("gemini-3.8-flash", "high")
    assert_equal 12_288, SorumatikOcr::AnswerGeneration.resolve_solve_max_output_tokens("gemini-3.7-flash", "low")
    assert_equal 12_288, SorumatikOcr::AnswerGeneration.resolve_solve_max_output_tokens("gemini-2.5-flash", "minimal")
    assert_equal 8_192, SorumatikOcr::AnswerGeneration.resolve_solve_max_output_tokens("gemini-2.0-flash", "default")
  end

  def test_ai_controller_proxy_max_output_tokens_scaling
    assert_equal 32_768, resolve_proxy_max_output_tokens("gemini-3.7-flash", is_json: false, thinking_level: "default")
    assert_equal 12_288, resolve_proxy_max_output_tokens("gemini-3.7-flash", is_json: false, thinking_level: "low")
    assert_equal 16_384, resolve_proxy_max_output_tokens("gemini-3.7-flash", is_json: true, thinking_level: "low")
    assert_equal 4_096, resolve_proxy_max_output_tokens("gemini-2.0-flash", is_json: false, thinking_level: "default")
    assert_equal 8_192, resolve_proxy_max_output_tokens("gemini-2.0-flash", is_json: true, thinking_level: "default")
  end

  def test_settings_yml_valid_and_uses_31_flash_lite_default_thinking_and_edumax_prompt
    settings_path = File.expand_path("../config/settings.yml", __dir__)
    parsed = YAML.load_file(settings_path)
    plugins = parsed.fetch("plugins")

    assert_equal "gemini-3.1-flash-lite", plugins.dig("gemini_ocr_model", "default")
    assert_equal "default", plugins.dig("gemini_ai_solve_thinking_level", "default")
    prompt = plugins.dig("gemini_ai_solve_system_prompt", "default").to_s
    assert_includes prompt, "EduMax AI — Sorumatik Expert Teacher System Prompt"
    assert_includes prompt, "STRICT TARGET-LANGUAGE & REGIONAL CURRICULUM LOCK"
    assert_includes prompt, "GEO (GENERATIVE ENGINE OPTIMIZATION)"

    mock_setting = Struct.new(:gemini_ocr_model, :gemini_ai_allowed_models).new(nil, nil)
    resolved_ocr = SorumatikOcr::SecurityPolicy.resolve_ocr_model(
      nil,
      site_setting: mock_setting,
      fallback: "gemini-3.1-flash-lite"
    )
    assert_equal "gemini-3.1-flash-lite", resolved_ocr
  end
end
