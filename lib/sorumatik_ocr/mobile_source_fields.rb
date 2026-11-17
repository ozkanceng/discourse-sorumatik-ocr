# frozen_string_literal: true

module SorumatikOcr
  # Copies the app's ownership fields from the create-post request onto the post.
  # Discourse only permits them (plugin.rb); nothing is stored unless set here.
  #
  # sorumatik_ai_backend=api and sorumatik_client_tier mark a question from the
  # new app: AnswerBackend.charge_for reads them on the first post and the answer
  # is charged to the asker on api.sorumatik.co.
  module MobileSourceFields
    CLIENT_TIERS = %w[free premium].freeze

    def setup_post
      super
      proto = @opts[:mobile_answer_protocol].to_i
      if proto >= 2 || @opts[:client_edge_solve].to_s == "true"
        @post.custom_fields["client_edge_solve"] = @opts[:client_edge_solve].to_s
        @post.custom_fields["mobile_answer_protocol"] = proto > 0 ? proto.to_s : "2"
      end
      if @opts[:mobile_source].to_s == "true"
        @post.custom_fields["mobile_source"] = "true"
      end
      if @opts[:sorumatik_ai_backend].to_s == "api"
        @post.custom_fields["sorumatik_ai_backend"] = "api"
        tier = @opts[:sorumatik_client_tier].to_s
        @post.custom_fields["sorumatik_client_tier"] = tier if CLIENT_TIERS.include?(tier)
      end
    end
  end
end
