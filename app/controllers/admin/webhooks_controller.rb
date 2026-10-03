# frozen_string_literal: true

module Admin
  class WebhooksController < Admin::ApplicationController
    def default_sorting_attribute
      :created_at
    end

    def default_sorting_direction
      :desc
    end
  end
end
