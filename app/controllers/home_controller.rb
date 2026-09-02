# frozen_string_literal: true

class HomeController < ApplicationController
  def index
    redirect_to mcp_servers_path if signed_in?
  end
end
