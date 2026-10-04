# frozen_string_literal: true

require "digest"

module McpServers
  module Whatsapp
    class InboundMessagesController < ApplicationController
      skip_forgery_protection

      def create
        server = McpServer.find_by(id: params[:id])
        if server.is_a?(Emcp::Servers::Telegram::Server)
          head :unauthorized and return unless telegram_token_match?(server)

          server.accept_inbound_message!(telegram_params)
          head :accepted
          return
        end
        head :not_found and return unless server.is_a?(Emcp::Servers::Whatsapp::Server)
        head :unauthorized and return unless bridge_token_match?(server)

        params.expect(:message_id)
        server.accept_inbound_message!(inbound_params)
        head :accepted
      end

      private

      def bridge_token_match?(server)
        presented = request.headers["X-Bridge-Token"].to_s
        stored = Emcp.sanitize_env_value(server.credentials_hash["WHATSAPP_BRIDGE_TOKEN"])
        return false if presented.blank? || stored.blank?

        ActiveSupport::SecurityUtils.secure_compare(
          Digest::SHA256.hexdigest(presented),
          Digest::SHA256.hexdigest(stored),
        )
      end

      def telegram_token_match?(server)
        presented = request.headers["X-Bridge-Token"].to_s
        stored = Emcp.sanitize_env_value(server.credentials_hash["TELEGRAM_BRIDGE_TOKEN"])
        return false if presented.blank? || stored.blank?

        ActiveSupport::SecurityUtils.secure_compare(
          Digest::SHA256.hexdigest(presented),
          Digest::SHA256.hexdigest(stored),
        )
      end

      def telegram_params
        params.permit(
          :message_id, :timestamp, :chat_id, :chat_title, :chat_type,
          :sender_id, :sender_name, :is_from_me, :skip_webhook, :mentions_owner, :muted, :text,
        ).to_h
      end

      def inbound_params
        params.permit(
          :message_id, :timestamp, :chat_jid, :chat_name, :is_group,
          :sender_jid, :sender_phone, :sender_name, :is_from_me, :skip_webhook, :type, :text,
          :quoted_message_id, :mentions_owner, media: %i[mimetype filename],
        ).to_h
      end
    end
  end
end
