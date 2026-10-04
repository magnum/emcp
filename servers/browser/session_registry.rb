# frozen_string_literal: true

require "securerandom"

module Emcp
  module Servers
    module Browser
      # In-process correlation of extension replies. Solid Cable delivers the
      # command to whichever web process holds the socket; the reply is also
      # written to the cache so another process waiting on the same request
      # can pick it up. One Puma worker is the expected deployment.
      class SessionRegistry
        class Offline < StandardError; end
        class TimedOut < StandardError; end

        def self.heartbeat_seconds
          raw = ENV["BROWSER_WS_HEARTBEAT"].presence || Emcp.server_setting("browser", "heartbeat", 15)
          seconds = raw.to_i
          seconds.positive? ? seconds : 15
        end

        def self.stale_after
          heartbeat_seconds * 3
        end

        def self.current
          @current ||= new
        end

        def self.current=(registry)
          @current = registry
        end

        def initialize
          @connections = {}
          @waiters = {}
          @mutex = Mutex.new
        end

        def attach(instance_id, connection = nil)
          generation = SecureRandom.hex(4)
          previous = nil
          @mutex.synchronize do
            previous = @connections[key(instance_id)]
            @connections[key(instance_id)] = {
              generation: generation,
              last_seen: monotonic,
              connection: connection,
            }
          end
          close_quietly(previous[:connection]) if previous && connection && previous[:connection] && previous[:connection] != connection
          generation
        end

        def detach(instance_id, generation)
          @mutex.synchronize do
            current = @connections[key(instance_id)]
            @connections.delete(key(instance_id)) if current && current[:generation] == generation
          end
        end

        def touch(instance_id)
          @mutex.synchronize do
            current = @connections[key(instance_id)]
            current[:last_seen] = monotonic if current
          end
        end

        def connected?(instance_id)
          @mutex.synchronize do
            current = @connections[key(instance_id)]
            current && (monotonic - current[:last_seen]) <= self.class.stale_after
          end
        end

        def supersede(instance_id)
          ActionCable.server.broadcast(stream_name(instance_id), { "kind" => "superseded" })
        rescue StandardError
          nil
        end

        def dispatch(instance_id, message, timeout:)
          raise Offline, "Chrome extension is offline" unless connected?(instance_id)

          request_id = SecureRandom.uuid
          queue = Queue.new
          @mutex.synchronize { @waiters[request_id] = queue }
          payload = message.merge("request_id" => request_id)
          yield payload if block_given?
          ActionCable.server.broadcast(stream_name(instance_id), payload) unless block_given?
          wait(request_id, queue, timeout)
        ensure
          @mutex.synchronize { @waiters.delete(request_id) } if request_id
        end

        def complete(request_id, payload)
          body = stringify(payload)
          Rails.cache.write(cache_key(request_id), body, expires_in: 2.minutes)
          @mutex.synchronize { @waiters[request_id] }&.push(body)
        end

        def stream_name(instance_id) = "browser:#{instance_id}"

        private

        def wait(request_id, queue, timeout)
          started = monotonic
          loop do
            raise TimedOut, "browser timed out after #{timeout}s" if monotonic - started > timeout

            begin
              item = queue.pop(timeout: 0.2)
              return item if item
            rescue ThreadError
              nil
            end
            cached = Rails.cache.read(cache_key(request_id))
            return cached if cached
          end
        end

        def key(instance_id) = instance_id.to_s

        def cache_key(request_id) = "browser/response/#{request_id}"

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def stringify(payload)
          payload.to_h.transform_keys(&:to_s)
        end

        def close_quietly(connection)
          connection.close
        rescue StandardError
          nil
        end
      end
    end
  end
end
