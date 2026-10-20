# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"

module Emcp
  class CliError < StandardError; end

  class CliClient
    attr_reader :bin

    def initialize(bin:, timeout: 30, max_bytes: nil, max_chars: nil, env: {})
      @bin = bin
      @timeout = timeout
      @max_bytes = positive_bytes(max_bytes) || positive_bytes(max_chars) || Emcp.max_response_bytes
      @env = env
    end

    def run(args, truncate: true)
      Current.mcp_command = [@bin, *Array(args)].shelljoin
      raise CliError, "binary '#{@bin}' not found in PATH" unless bin_available?

      child_env = ENV.to_h.dup
      # jemalloc is preloaded into Puma; musl CLIs (gws) inherit it and then
      # fail getaddrinfo. spawn merges env hashes, so a missing key is kept —
      # nil is required to actually unset it in the child.
      child_env["LD_PRELOAD"] = nil
      @env.each do |key, value|
        key = key.to_s
        child_env[key] = value.nil? ? nil : value.to_s
      end

      Open3.popen3(child_env, @bin, *args) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        out_reader = Thread.new { read_stream(stdout) }
        err_reader = Thread.new { read_stream(stderr) }

        unless wait_thr.join(@timeout)
          Process.kill("KILL", wait_thr.pid)
          raise CliError, "timeout after #{@timeout}s: #{@bin} #{args.join(" ")}"
        end

        out = out_reader.value.to_s.strip
        err = err_reader.value.to_s.strip
        unless wait_thr.value.success?
          detail = err.empty? ? out : err
          raise CliError, "#{@bin} exited #{wait_thr.value.exitstatus}: #{detail[0, 800]}"
        end

        truncate ? truncate_output(out) : out
      end
    rescue Errno::ESRCH
      raise CliError, "process terminated while running #{@bin}"
    end

    private

    def bin_available?
      return File.executable?(@bin) if @bin.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, @bin))
      end
    end

    def read_stream(io)
      buffer = +"".b
      loop do
        chunk = io.readpartial(16_384)
        buffer << chunk
      rescue EOFError
        break
      end
      buffer.force_encoding(Encoding::UTF_8).scrub
    end

    def truncate_output(text)
      raw = text.to_s
      total = raw.b.bytesize
      return raw if total <= @max_bytes

      kept = utf8_prefix(raw, @max_bytes)
      JSON.generate(
        "truncated" => true,
        "total_bytes" => total,
        "returned_bytes" => kept.b.bytesize,
        "message" => "Response exceeded #{@max_bytes} bytes. Narrow the request with limit, page, or a filter, " \
          "or raise EMCP_MAX_RESPONSE_BYTES or servers.<code>.max_response_bytes.",
        "output" => kept
      )
    end

    def utf8_prefix(text, max_bytes)
      slice = text.b.byteslice(0, max_bytes).to_s
      slice.force_encoding(Encoding::UTF_8)
      slice = slice.byteslice(0...-1).force_encoding(Encoding::UTF_8) until slice.valid_encoding? || slice.empty?
      slice
    end

    def positive_bytes(value)
      return nil if value.nil? || value.to_s.strip.empty?

      number = value.to_i
      number.positive? ? number : nil
    end
  end
end
