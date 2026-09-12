# frozen_string_literal: true

class McpServersController < ApplicationController
  before_action :require_authentication
  before_action :load_catalog
  before_action :set_server, only: %i[show edit update destroy]

  def index
    @servers = current_user.mcp_servers.includes(:mcp_server_type).order(:name)
    @servers = @servers.where(mcp_server_type_id: params[:mcp_server_type_id]) if params[:mcp_server_type_id].present?
    @servers = @servers.search(params[:q])
    @user_tags = McpServer.tag_names_for(current_user)
    @active_search_tags = McpServer.parse_search_query(params[:q])[:tags]
  end

  def show
  end

  def new
    @server = current_user.mcp_servers.new
  end

  def create
    @server = current_user.mcp_servers.new(server_params)
    if @server.save
      redirect_to auth_mcp_server_path(@server), notice: "Server created"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @server.update(server_params)
      redirect_to @server, notice: "Server updated"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @server.destroy!
    redirect_to mcp_servers_path, notice: "Server deleted"
  end

  def tags
    names = current_user.mcp_servers.flat_map { |server| server.tag_list }.uniq.sort
    query = params[:q].to_s.downcase
    names.select! { |name| name.downcase.include?(query) } if query.present?
    render json: names
  end

  private

  def load_catalog
    McpServerType.discover!
    @server_types = McpServerType.order(:name)
  end

  def set_server
    @server = current_user.mcp_servers.find(params[:id])
  end

  def server_params
    permitted = [ :name, :description, :tag_list ]
    permitted << :mcp_server_type_id if action_name == "create"
    params.require(:mcp_server).permit(permitted)
  end
end
