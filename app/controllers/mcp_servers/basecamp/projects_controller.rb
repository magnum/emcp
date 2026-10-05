# frozen_string_literal: true

module McpServers
  module Basecamp
    class ProjectsController < ApplicationController
      before_action :require_authentication
      before_action :set_server

      def index
        @linked = @server.basecamp_projects.order(:name).index_by(&:project_id)
        @projects = @server.remote_projects
      rescue Emcp::CliError => e
        @linked ||= @server.basecamp_projects.order(:name).index_by(&:project_id)
        @projects = []
        @cli_error = e.message
      end

      def create
        project = @server.link_basecamp_project!(**project_params)
        redirect_to @server, notice: "Linked #{project.name}. Basecamp will post comments and messages to EmCP."
      rescue StandardError => e
        redirect_to mcp_server_basecamp_projects_path(@server), alert: e.message
      end

      def destroy
        project = @server.basecamp_projects.find(params[:id])
        project.unlink!
        redirect_to @server, notice: "Unlinked #{project.name}. The Basecamp webhook was removed."
      rescue Emcp::CliError => e
        redirect_to @server, alert: e.message
      end

      private

      def set_server
        @server = current_user.mcp_servers.find(params[:mcp_server_id])
        raise ActiveRecord::RecordNotFound unless @server.is_a?(Emcp::Servers::Basecamp::Server)
      end

      def project_params
        params.expect(basecamp_project: [ :project_id, :name ]).to_h.symbolize_keys
      end
    end
  end
end
