# frozen_string_literal: true

require "base64"
require "json"
require "rqrcode"
require_relative "session_registry"

module Emcp
  module Servers
    module Browser
      module Pairing
        module_function

        def token_matches?(server, token)
          stored = server.credentials_hash["BROWSER_PAIRING_TOKEN"].to_s
          return false if stored.empty? || token.blank?

          Emcp.secure_equals(stored, token)
        end

        def payload_for(server)
          token = server.credentials_hash["BROWSER_PAIRING_TOKEN"].to_s
          return if token.empty? || server.id.blank?

          {
            "v" => 1,
            "ws" => cable_url,
            "instance_id" => server.id,
            "token" => token,
            "origins" => OriginPolicy.parse(server.credentials_hash["BROWSER_ALLOWED_ORIGINS"]),
            "heartbeat" => SessionRegistry.heartbeat_seconds_for(server),
          }
        end

        def qr_png_base64(server)
          payload = payload_for(server)
          return if payload.nil?

          png = RQRCode::QRCode.new(JSON.generate(payload), level: :l).as_png(size: 280, border_modules: 2)
          Base64.strict_encode64(png.to_s)
        end

        def cable_url
          public = Emcp.public_url
          ws = public.sub(/\Ahttp/i, "ws")
          "#{ws}/cable"
        end
      end
    end
  end
end
