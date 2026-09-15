# frozen_string_literal: true

module Emcp
  module Servers
    module Whatsapp
      # The Go sidecar binds 127.0.0.1 inside the *web* container. Kamal's Solid
      # Queue worker is a different container, so keepalive must run next to Puma
      # (not as a worker job that would spawn a second, unreachable process).
      class Keepalive
        INTERVAL = 30

        class << self
          def start_in_puma
            return if Rails.env.test?
            return unless can_spawn_locally?
            return if @thread&.alive?

            @thread = Thread.new { new.loop_forever }
            @thread.name = "whatsapp-keepalive"
            @thread.abort_on_exception = false
            @thread
          end

          def can_spawn_locally?
            return false if ENV["SOLID_QUEUE_WORKER"].present?
            return false if ARGV.any? { |arg| arg.to_s.include?("solid_queue") }

            true
          end

          def ping_all
            new.ping_all
          end
        end

        def loop_forever
          sleep 2
          ping_all
          loop do
            sleep INTERVAL
            ping_all
          end
        rescue StandardError => e
          Rails.logger.error("[whatsapp keepalive] loop crashed: #{e.class}: #{e.message}")
        end

        def ping_all
          Rails.application.executor.wrap do
            servers.find_each do |server|
              ping(server)
            end
          end
        rescue StandardError => e
          Rails.logger.error("[whatsapp keepalive] #{e.class}: #{e.message}")
        end

        def ping(server)
          server.keep_bridge_alive!
        rescue StandardError => e
          Rails.logger.warn("[whatsapp keepalive] server=#{server.id} #{e.message}")
        end

        def servers
          McpServer.joins(:mcp_server_type).where(mcp_server_types: { code: "whatsapp" })
        end
      end
    end
  end
end
