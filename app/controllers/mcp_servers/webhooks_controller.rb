# frozen_string_literal: true

module McpServers
  class WebhooksController < ApplicationController
    before_action :require_authentication
    before_action :set_server
    before_action :set_hook, only: %i[edit update destroy test]

    def new
      @hook = hook_scope.new
    end

    def create
      @hook = hook_scope.new(hook_params)
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
      return if @server.is_a?(Emcp::Servers::Whatsapp::Server) || @server.is_a?(Emcp::Servers::Telegram::Server)

      raise ActiveRecord::RecordNotFound
    end

    def set_hook
      @hook = hook_scope.find(params[:id])
    end

    def hook_scope
      @server.is_a?(Emcp::Servers::Telegram::Server) ? @server.telegram_hooks : @server.whatsapp_hooks
    end

    def hook_params
      return telegram_hook_params if @server.is_a?(Emcp::Servers::Telegram::Server)

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

    def telegram_hook_params
      permitted = params.expect(telegram_hook: [
        :url, :secret, :secret_header, :enabled, :respond_by_status, :chat_ids,
        :mentions_only, :ignore_muted, :ignore_channels, :debounce_minutes,
        chat_types: [],
      ])
      permitted.delete(:secret) if permitted[:secret].blank?
      if permitted.key?(:chat_types)
        permitted[:chat_types] = Emcp::Servers::Telegram::Hook.normalize_chat_types(permitted[:chat_types])
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
