# frozen_string_literal: true

module McpServers
  class ContextMembershipsController < ApplicationController
    before_action :require_authentication
    before_action :set_context

    def create
      membership = @context.context_memberships.new(create_params)
      if membership.save
        redirect_to @context, notice: "Server added to context"
      else
        redirect_to @context, alert: membership.errors.full_messages.to_sentence
      end
    end

    def update
      membership = @context.context_memberships.find(params[:id])
      membership.update!(update_params)
      redirect_to @context, notice: membership.active? ? "Server enabled" : "Server paused"
    end

    def destroy
      @context.context_memberships.find(params[:id]).destroy!
      redirect_to @context, notice: "Server removed from context"
    end

    private

    def set_context
      @context = current_user.mcp_servers.find(params[:mcp_server_id])
      raise ActiveRecord::RecordNotFound unless @context.context?
    end

    def create_params
      params.expect(context_membership: [ :mcp_server_id ])
    end

    def update_params
      params.expect(context_membership: [ :active ])
    end
  end
end
