# frozen_string_literal: true
require "minitest/autorun"
require "time"

# Minimal stubs to test AnswerGeneration logic in isolation
module SorumatikOcr
  module GeminiAnswerStream
    class Failure < StandardError
      attr_reader :code
      def initialize(code); @code = code; super(code); end
    end
  end
  class AiGeneration
    def self.exists?(**_kwargs); false; end
  end
end

class MockSiteSetting
  attr_accessor :gemini_ai_solve_enabled, :gemini_ai_solve_bot_username, :gemini_ai_suppress_automation_bot_username, :gemini_ai_solve_category_ids
  def initialize
    @gemini_ai_solve_enabled = true
    @gemini_ai_solve_bot_username = "sorumatik_ai"
    @gemini_ai_suppress_automation_bot_username = "sorumatik_uzman_bot"
    @gemini_ai_solve_category_ids = "163|162|164|6|7|8|9|10|11|12"
  end
end

SiteSetting = MockSiteSetting.new unless defined?(SiteSetting)

class Post
  def self.types
    { regular: 1 }
  end
end unless defined?(Post)

class MockTopic
  attr_accessor :tags, :custom_fields, :posts, :id, :category_id, :first_post
  def initialize
    @id = 123
    @category_id = 163
    @tags = []
    @custom_fields = {}
    @posts = []
    @first_post = nil
  end
end

class MockTagList
  def initialize(tags = [])
    @tags = tags
  end
  def exists?(name:)
    @tags.include?(name)
  end
  def <<(name)
    @tags << name
  end
end

class MockPost
  attr_accessor :id, :post_number, :created_at, :custom_fields, :topic, :user, :deleted_at, :post_type, :raw
  def initialize(created_at = Time.now)
    @id = 1
    @post_number = 1
    @created_at = created_at
    @custom_fields = {}
    @topic = MockTopic.new
    @topic.tags = MockTagList.new(["soru-cozumu"])
    @topic.first_post = self
    @user = Struct.new(:username).new("student")
    @deleted_at = nil
    @post_type = 1
    @raw = "Matematik sorusu"
  end
  def reply_to_post; nil; end
end

class MockGuardian
  def initialize(user); end
  def can_see?(topic); true; end
end

Guardian = MockGuardian unless defined?(Guardian)

require_relative "../lib/sorumatik_ocr/answer_generation"
require_relative "../lib/sorumatik_ocr/managed_ai_reply"

class FallbackAnswerTest < Minitest::Test
  def setup
    @post = MockPost.new(Time.now)
    @post.custom_fields["client_edge_solve"] = "true"
    @post.custom_fields["mobile_answer_protocol"] = "2"
  end

  def test_fresh_client_edge_post_is_client_owned
    assert_equal true, SorumatikOcr::AnswerGeneration.client_owned_source?(@post)
  end

  def test_expired_client_edge_post_is_not_client_owned
    # Created 100 seconds ago (lease is 90 seconds)
    expired_post = MockPost.new(Time.now - 100)
    expired_post.custom_fields["client_edge_solve"] = "true"
    expired_post.custom_fields["mobile_answer_protocol"] = "2"
    assert_equal false, SorumatikOcr::AnswerGeneration.client_owned_source?(expired_post)
  end

  def test_post_without_edge_flags_is_not_client_owned
    regular_post = MockPost.new(Time.now)
    assert_equal false, SorumatikOcr::AnswerGeneration.client_owned_source?(regular_post)
  end

  def test_post_with_older_protocol_is_not_client_owned
    old_proto_post = MockPost.new(Time.now)
    old_proto_post.custom_fields["client_edge_solve"] = "true"
    old_proto_post.custom_fields["mobile_answer_protocol"] = "1"
    assert_equal false, SorumatikOcr::AnswerGeneration.client_owned_source?(old_proto_post)
  end

  def test_managed_source_false_while_fresh_then_true_when_expired
    # When fresh: managed_source? must be false so server doesn't solve immediately
    assert_equal false, SorumatikOcr::AnswerGeneration.managed_source?(@post)

    # When expired (e.g. 100 seconds later): managed_source? must be true so server fallback takes over
    @post.created_at = Time.now - 100
    assert_equal true, SorumatikOcr::AnswerGeneration.managed_source?(@post)
  end

  def test_managed_ai_reply_gracefully_skips_automation_bot
    skip_caller = Object.new
    skip_caller.extend(SorumatikOcr::ManagedAiReply)
    skip_caller.instance_variable_set(:@bot_user, Struct.new(:username).new("sorumatik_uzman_bot"))

    # When reply_to is called for sorumatik_uzman_bot on a soru-cozumu topic, it should return nil
    result = skip_caller.reply_to(@post)
    assert_nil result
  end

  def test_question_topic_detected_by_soru_cozumu_tag
    topic_with_tag = MockTopic.new
    topic_with_tag.tags = MockTagList.new(["soru-cozumu"])
    assert_equal true, SorumatikOcr::AnswerGeneration.question_topic?(topic_with_tag)
  end

  def test_question_topic_detected_by_client_edge_solve
    topic = MockTopic.new
    topic.tags = MockTagList.new([])
    topic.custom_fields["client_edge_solve"] = "true"
    assert_equal true, SorumatikOcr::AnswerGeneration.question_topic?(topic)
  end

  def test_non_question_topic_without_tag_or_flag_is_false
    regular_topic = MockTopic.new
    regular_topic.tags = MockTagList.new([])
    SiteSetting.gemini_ai_solve_category_ids = ""
    assert_equal false, SorumatikOcr::AnswerGeneration.question_topic?(regular_topic)
  end

  def test_question_topic_respects_explicit_category_setting
    topic = MockTopic.new
    topic.tags = MockTagList.new([])
    topic.category_id = 163
    SiteSetting.gemini_ai_solve_category_ids = "163|162"
    assert_equal true, SorumatikOcr::AnswerGeneration.question_topic?(topic)
    SiteSetting.gemini_ai_solve_category_ids = ""
  end

  def test_managed_ai_reply_skips_automation_bot_on_soru_cozumu_tagged_topic
    post = MockPost.new(Time.now)
    post.topic.tags = MockTagList.new(["soru-cozumu"])

    skip_caller = Object.new
    skip_caller.extend(SorumatikOcr::ManagedAiReply)
    skip_caller.instance_variable_set(:@bot_user, Struct.new(:username).new("sorumatik_uzman_bot"))

    result = skip_caller.reply_to(post)
    assert_nil result
  end

  def test_managed_ai_reply_skips_automation_bot_on_client_edge_solve_topic
    post = MockPost.new(Time.now)
    post.topic.tags = MockTagList.new([])
    post.custom_fields["client_edge_solve"] = "true"

    skip_caller = Object.new
    skip_caller.extend(SorumatikOcr::ManagedAiReply)
    skip_caller.instance_variable_set(:@bot_user, Struct.new(:username).new("sorumatik_uzman_bot"))

    result = skip_caller.reply_to(post)
    assert_nil result
  end

  def test_managed_ai_reply_skips_automation_bot_via_bot_method
    post = MockPost.new(Time.now)
    post.topic.tags = MockTagList.new(["soru-cozumu"])

    skip_caller = Object.new
    skip_caller.extend(SorumatikOcr::ManagedAiReply)
    def skip_caller.bot_user
      Struct.new(:username).new("sorumatik_uzman_bot")
    end

    result = skip_caller.reply_to(post)
    assert_nil result
  end

  def test_markdown_image_regex_extracts_urls
    raw = "Matematik sorusu\n\n![Soru görseli](https://sorumatik.co/uploads/default/original/3X/6/e/test.jpeg)"
    urls = raw.scan(/!\[.*?\]\(((?:https?:)?\/\/[^\s\)]+)\)/i).flatten
    assert_equal 1, urls.length
    assert_equal "https://sorumatik.co/uploads/default/original/3X/6/e/test.jpeg", urls.first
  end
end
