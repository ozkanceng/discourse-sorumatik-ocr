# frozen_string_literal: true

# name: discourse-sorumatik-ocr
# about: Sorumatik için ultra hızlı Google Gemini 2.5 Flash-Lite tabanlı Matematik/Sınav OCR eklentisi.
# version: 1.0.0
# authors: Sorumatik
# url: https://github.com/ozkanceng/discourse-sorumatik-ocr

enabled_site_setting :gemini_ocr_enabled

after_initialize do
  module ::SorumatikOcr
    PLUGIN_NAME = "discourse-sorumatik-ocr"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace SorumatikOcr
    end
  end

  require_relative "app/controllers/sorumatik_ocr/ocr_controller"
  require_relative "app/controllers/sorumatik_ocr/ai_solve_controller"

  SorumatikOcr::Engine.routes.draw do
    post "/ocr" => "ocr#extract"
    post "/stream-solve" => "ai_solve#stream"
    post "/ai-solve" => "ai_solve#stream"
  end

  Discourse::Application.routes.append do
    mount ::SorumatikOcr::Engine, at: "/sorumatik"
  end
end
