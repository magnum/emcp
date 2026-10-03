# frozen_string_literal: true

require "administrate/base_dashboard"

module Emcp
  module Servers
    module Whatsapp
      # Administrate looks this up when a Webhook row points at a WhatsApp hook.
      # There is no admin page for the hook; the label is enough for the link text.
      class HookDashboard < Administrate::BaseDashboard
        ATTRIBUTE_TYPES = {
          id: Field::Number,
          url: Field::String,
          enabled: Field::Boolean,
          owner_status: Field::String,
          respond_when: Field::String,
          consider_words: Field::String,
          history_limit: Field::Number,
          created_at: Field::DateTime,
          updated_at: Field::DateTime
        }.freeze

        COLLECTION_ATTRIBUTES = %i[id url respond_when enabled].freeze
        SHOW_PAGE_ATTRIBUTES = COLLECTION_ATTRIBUTES
        FORM_ATTRIBUTES = [].freeze
        COLLECTION_FILTERS = {}.freeze

        def display_resource(hook)
          "WhatsApp hook ##{hook.id}"
        end
      end
    end
  end
end
