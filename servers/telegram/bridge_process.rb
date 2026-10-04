# frozen_string_literal: true

require "fileutils"

module Emcp
  module Servers
    module Telegram
      class BridgeProcess
        START_TIMEOUT = 20
        DEFAULT_BINARY = File.expand_path("bridge/telegram-bridge", __dir__)

        attr_reader :store_dir, :binary, :token, :inbound_url, :api_id, :api_hash, :phone, :session_key

        def initialize(store_dir:, binary:, token: nil, inbound_url: nil, api_id: nil, api_hash: nil, phone: nil, session_key: nil)
          @store_dir = store_dir.to_s
          @binary = binary.to_s
          @token = token.to_s
          @inbound_url = inbound_url.to_s
          @api_id = api_id.to_s
          @api_hash = api_hash.to_s
          @phone = phone.to_s
          @session_key = session_key.to_s
        end

        def configured?
          resolved_binary.present?
        end

        def missing_binary_message
          "Telegram bridge binary not found (#{binary.presence || "unset"}). " \
            "Build it with: cd servers/telegram/bridge && go build -o telegram-bridge ."
        end

        def resolved_binary
          candidates = [ binary, DEFAULT_BINARY, "telegram-bridge" ]
          candidates.find { |path| path.present? && path.include?("/") && File.executable?(path) } ||
            find_on_path(binary.presence || "telegram-bridge")
        end

        def running?
          process_alive?(read_pid)
        end

        def url
          return unless File.file?(url_file)

          Emcp.sanitize_env_value(File.read(url_file))
        end

        def ensure_running!
          if running? && url.present? && inbound_current?
            return url
          end

          stop! if running?
          start!
          url
        end

        def start!
          raise missing_binary_message unless configured?

          FileUtils.mkdir_p(store_dir)
          File.write(inbound_file, inbound_url, perm: 0o600)
          File.open(lock_file, File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            return url if running? && url.present?

            stop_stale!
            FileUtils.rm_f(url_file)
            pid = Process.spawn(
              spawn_env,
              resolved_binary,
              chdir: store_dir,
              out: [ log_file, "a" ],
              err: [ log_file, "a" ],
              pgroup: true,
            )
            Process.detach(pid)
            File.write(pid_file, "#{pid}\n")
            wait_for_url!
            url
          end
        end

        def stop!
          pid = read_pid
          if pid
            Process.kill("TERM", -pid)
            20.times do
              break unless process_alive?(pid)

              sleep 0.1
            end
            Process.kill("KILL", -pid) if process_alive?(pid)
          end
        rescue Errno::ESRCH, Errno::EPERM, Errno::EINVAL
          nil
        ensure
          FileUtils.rm_f(pid_file)
          FileUtils.rm_f(url_file)
        end

        def pid_file = File.join(store_dir, "bridge.pid")
        def url_file = File.join(store_dir, "bridge.url")
        def lock_file = File.join(store_dir, "bridge.lock")
        def log_file = File.join(store_dir, "bridge.log")
        def inbound_file = File.join(store_dir, "bridge.inbound_url")
        def session_file = File.join(store_dir, "session.bin")

        private

        def find_on_path(name)
          return if name.blank? || name.include?(File::SEPARATOR)

          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
            path = File.join(dir, name)
            return path if File.executable?(path)
          end
          nil
        end

        def spawn_env
          env = {
            "TELEGRAM_STORE_DIR" => store_dir,
            "TELEGRAM_LISTEN" => "127.0.0.1:0",
            "TELEGRAM_URL_FILE" => url_file,
            "TELEGRAM_BRIDGE_TOKEN" => token,
            "TELEGRAM_API_ID" => api_id,
            "TELEGRAM_API_HASH" => api_hash,
            "TELEGRAM_PHONE" => phone,
            "TELEGRAM_SESSION_KEY" => session_key,
          }
          env["TELEGRAM_INBOUND_URL"] = inbound_url if inbound_url.present?
          env
        end

        def inbound_current?
          recorded = File.file?(inbound_file) ? File.read(inbound_file).strip : ""
          recorded == inbound_url
        end

        def wait_for_url!
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + START_TIMEOUT
          loop do
            return if url.present? && running?

            if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              raise "Telegram bridge did not start within #{START_TIMEOUT}s. See #{log_file}"
            end

            sleep 0.2
          end
        end

        def stop_stale!
          return if running?

          FileUtils.rm_f(pid_file)
        end

        def read_pid
          return unless File.file?(pid_file)

          Integer(File.read(pid_file).to_s.strip, exception: false)
        end

        def process_alive?(pid)
          return false unless pid

          Process.kill(0, pid)
          true
        rescue Errno::ESRCH, Errno::EPERM
          false
        end
      end
    end
  end
end
