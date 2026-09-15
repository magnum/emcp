# frozen_string_literal: true

require "timeout"

module Emcp
  class RequestTimeout
    SKIP_PREFIXES = [ "/up", "/health", "/healthz" ].freeze

    def initialize(app, timeout: 20)
      @app = app
      @timeout = timeout
    end

    def call(env)
      seconds = timeout_for(env)
      return @app.call(env) if seconds.nil?

      ::Timeout.timeout(seconds) { @app.call(env) }
    rescue ::Timeout::Error
      [ 504, { "Content-Type" => "text/plain; charset=utf-8" }, [ "Gateway Timeout" ] ]
    end

    private

    def timeout_for(env)
      path = env["PATH_INFO"].to_s
      return if SKIP_PREFIXES.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }

      @timeout
    end
  end
end
