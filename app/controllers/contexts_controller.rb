# frozen_string_literal: true

class ContextsController < ApplicationController
  before_action :require_authentication
  before_action :load_context_type

  def index
    @contexts = current_user.mcp_servers.contexts.includes(:mcp_server_type, :context_memberships).order(:name)
    @contexts = @contexts.search(params[:q])
    @user_tags = McpServer.tag_names_for(current_user)
    @active_search_tags = McpServer.parse_search_query(params[:q])[:tags]
  end

  def new
    @server = current_user.mcp_servers.new(mcp_server_type: @context_type)
  end

  def create
    @server = current_user.mcp_servers.new(context_params)
    @server.mcp_server_type = @context_type
    if @server.save
      redirect_to mcp_server_path(@server), notice: "Context created — add the servers it should proxy."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def load_context_type
    McpServerType.discover!
    @context_type = McpServerType.fetch!("context")
  end

  def context_params
    params.require(:mcp_server).permit(:name, :description, :tag_list)
  end
end
