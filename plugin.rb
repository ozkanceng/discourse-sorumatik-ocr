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

  # Mobilden sorulan (soru-cozumu etiketli) konularda web otomasyon botunun (@sorumatik_uzman_bot) çift cevap vermesini engelle
  validate(:post, :validate_sorumatik_automation_suppression) do
    suppress_bot = SiteSetting.gemini_ai_suppress_automation_bot_username.presence || "sorumatik_uzman_bot"
    return if user.blank? || !user.username.to_s.casecmp?(suppress_bot)

    if topic.present? && (topic.tags.exists?(name: "soru-cozumu") || topic.custom_fields["ai_solve_handled"].present?)
      Rails.logger.info("[Sorumatik AI] Suppressing automation bot #{suppress_bot} for topic ##{topic_id} (tagged: soru-cozumu)")
      errors.add(:base, "Bu konu mobil uygulama çözümü içerdiği için otomasyon botu yanıtı engellendi.")
    end
  end

  on(:before_create_post) do |post|
    suppress_bot = SiteSetting.gemini_ai_suppress_automation_bot_username.presence || "sorumatik_uzman_bot"
    if post.user.present? && post.user.username.to_s.casecmp?(suppress_bot)
      t = post.topic
      if t.present? && (t.tags.exists?(name: "soru-cozumu") || t.custom_fields["ai_solve_handled"].present?)
        Rails.logger.info("[Sorumatik AI] Halting automation bot #{suppress_bot} post creation on topic ##{t.id}")
        throw(:abort)
      end
    end
  end
end
