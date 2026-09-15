# frozen_string_literal: true

module Emcp
  module Servers
    module Whatsapp
      # The Go sidecar binds 127.0.0.1 inside the *web* container. Kamal's Solid
      # Queue worker is a different container, so keepalive must run next to Puma
      # (not as a worker job that would spawn a second, unreachable process).
      class Keepalive
        INTERVAL = 30
        SUPERVISE_INTERVAL = 60

        class << self
          def start_in_puma(force: false)
            return if Rails.env.test? && !force
            return unless can_spawn_locally?
            return if alive?

            @thread = Thread.new { new.loop_forever }
            @thread.name = "whatsapp-keepalive"
            @thread.abort_on_exception = false
            @thread
          end

          def supervise(interval: SUPERVISE_INTERVAL, force: false)
            return if Rails.env.test? && !force
            return unless can_spawn_locally?
            return if @supervisor&.alive?

            @supervisor = Thread.new do
              loop do
                sleep interval
                unless alive?
                  Rails.logger.warn("[whatsapp keepalive] thread morto, riavvio")
                  start_in_puma(force: force)
                end
              end
            end
            @supervisor.name = "whatsapp-keepalive-supervisor"
            @supervisor.abort_on_exception = false
            @supervisor
          end

          def alive?
            @thread&.alive? || false
          end

          def can_spawn_locally?
            return false if Emcp.env_flag?("SOLID_QUEUE_WORKER")
            return false if ARGV.any? { |arg| arg.to_s.include?("solid_queue") }

            true
          end

          def ping_all
            new.ping_all
          end

          def kill_worker_for_test
            @thread&.kill
            @thread&.join(0.5)
            @thread = nil
          end

          def stop_for_test
            kill_worker_for_test
            @supervisor&.kill
            @supervisor&.join(0.5)
            @supervisor = nil
          end
        end

        def loop_forever(interval: INTERVAL, iterations: nil)
          sleep 2 unless iterations
          count = 0
          loop do
            begin
              ping_all
            rescue StandardError => e
              Rails.logger.error("[whatsapp keepalive] tick failed: #{e.class}: #{e.message}")
            end
            count += 1
            break if iterations && count >= iterations

            sleep interval
          end
        end

        def ping_all
          Rails.application.executor.wrap do
            servers.find_each do |server|
              ping(server)
            end
          end
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
