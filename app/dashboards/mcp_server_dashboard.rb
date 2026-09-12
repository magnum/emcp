# frozen_string_literal: true

require "administrate/base_dashboard"
require "administrate/field/acts_as_taggable"

class McpServerDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    user: Field::BelongsTo,
    mcp_server_type: Field::BelongsTo,
    type: Field::String,
    name: Field::String,
    description: Field::Text,
    allow_write: Field::Boolean,
    token_refresh_in_minutes: Field::Number,
    service_token_refresh_in_minutes: Field::Number,
    tags: Field::ActsAsTaggable,
    created_at: Field::DateTime,
    updated_at: Field::DateTime,
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id name user mcp_server_type tags allow_write].freeze
  SHOW_PAGE_ATTRIBUTES = %i[
    id user mcp_server_type type name description tags allow_write
    token_refresh_in_minutes service_token_refresh_in_minutes created_at updated_at
  ].freeze
  FORM_ATTRIBUTES = %i[
    user mcp_server_type name description tags allow_write
    token_refresh_in_minutes service_token_refresh_in_minutes
  ].freeze
  COLLECTION_FILTERS = {}.freeze

  def display_resource(server)
    "#{server.name} (#{server.try(:code) || server.id})"
  end
end
