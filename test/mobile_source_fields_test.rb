# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/sorumatik_ocr/mobile_source_fields"
require_relative "../lib/sorumatik_ocr/rollout_flags"

class MobileSourceFieldsTest < Minitest::Test
  FakePost = Struct.new(:custom_fields, :id, :post_number, :topic)
  FakeTopic = Struct.new(:first_post)

  class BaseCreator
    attr_reader :post

    def initialize(opts)
      @opts = opts
    end

    def setup_post
      @post = FakePost.new({}, 7, 1, nil)
      @post.topic = FakeTopic.new(@post)
    end
  end

  class Creator < BaseCreator
    prepend SorumatikOcr::MobileSourceFields
  end

  def fields(opts)
    creator = Creator.new(opts)
    creator.setup_post
    creator.post.custom_fields
  end

  APP_QUESTION = { mobile_answer_protocol: "3", client_edge_solve: "false", mobile_source: "true",
                   is_mobile: "true", sorumatik_ai_backend: "api", sorumatik_client_tier: "free" }.freeze

  def test_new_app_question_keeps_the_charge_marker_and_tier
    assert_equal({ "client_edge_solve" => "false", "mobile_answer_protocol" => "3", "mobile_source" => "true",
                   "sorumatik_ai_backend" => "api", "sorumatik_client_tier" => "free" }, fields(APP_QUESTION))
    assert_equal "premium", fields(APP_QUESTION.merge(sorumatik_client_tier: "premium"))["sorumatik_client_tier"]
  end

  def test_unknown_values_are_not_stored
    assert_nil fields(APP_QUESTION.merge(sorumatik_ai_backend: "forum"))["sorumatik_ai_backend"]
    assert_nil fields(APP_QUESTION.merge(sorumatik_ai_backend: "forum"))["sorumatik_client_tier"]
    stored = fields(APP_QUESTION.merge(sorumatik_client_tier: "ultra"))
    assert_equal "api", stored["sorumatik_ai_backend"]
    refute stored.key?("sorumatik_client_tier")
  end

  def test_older_app_question_is_unchanged
    stored = fields(mobile_answer_protocol: "2", client_edge_solve: "true", mobile_source: "true")
    assert_equal({ "client_edge_solve" => "true", "mobile_answer_protocol" => "2", "mobile_source" => "true" }, stored)
  end

  def test_stored_question_is_charged_through_the_api
    creator = Creator.new(APP_QUESTION)
    creator.setup_post
    assert_equal({ feature: "ask_question", key: "qa:post:7", tier: "free" },
                 SorumatikOcr::AnswerBackend.charge_for(creator.post))

    plain = Creator.new(mobile_source: "true")
    plain.setup_post
    assert_nil SorumatikOcr::AnswerBackend.charge_for(plain.post)
  end
end
