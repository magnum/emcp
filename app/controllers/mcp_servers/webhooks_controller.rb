# frozen_string_literal: true

module McpServers
  class WebhooksController < ApplicationController
    before_action :require_authentication
    before_action :set_server
    before_action :set_hook, only: %i[edit update destroy test]

    def new
      @hook = @server.whatsapp_hooks.new
    end

    def create
      @hook = @server.whatsapp_hooks.new(hook_params)
      if @hook.save
        redirect_to @server, notice: "Webhook saved. The secret is stored encrypted and will not be shown again."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @hook.update(hook_params)
        redirect_to @server, notice: "Webhook updated"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @hook.destroy!
      redirect_to @server, notice: "Webhook removed"
    end

    def test
      record = @hook.deliver_test!
      redirect_to mcp_server_edit_webhook_path(@server, @hook), notice: test_notice(record)
    rescue StandardError => e
      record = @hook.webhooks.order(:id).last
      redirect_to mcp_server_edit_webhook_path(@server, @hook), alert: record ? test_notice(record) : e.message
    end

    private

    def set_server
      @server = current_user.mcp_servers.find(params[:mcp_server_id])
      raise ActiveRecord::RecordNotFound unless @server.is_a?(Emcp::Servers::Whatsapp::Server)
    end

    def set_hook
      @hook = @server.whatsapp_hooks.find(params[:id])
    end

    def hook_params
      permitted = params.expect(whatsapp_hook: [
        :url, :secret, :secret_header, :respond_when, :consider_words, :history_limit,
        chat_kinds: [],
      ])
      permitted.delete(:secret) if permitted[:secret].blank?
      if permitted.key?(:chat_kinds)
        permitted[:chat_kinds] = Emcp::Servers::Whatsapp::Hook.normalize_chat_kinds(permitted[:chat_kinds])
      end
      if permitted.key?(:history_limit)
        raw = permitted[:history_limit].presence
        number = raw&.to_i
        permitted[:history_limit] = (number.nil? || number == Emcp::Servers::Whatsapp::ChatHistory.limit) ? nil : number
      end
      permitted
    end

    def test_notice(record)
      code = record.response_code
      return "Test failed: #{record.error_message}" if code.blank?

      "Test HTTP #{code}: #{record.read_attribute(:response_body).to_s.truncate(240)}"
    end
  end
end
