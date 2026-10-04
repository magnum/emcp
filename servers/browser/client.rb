# frozen_string_literal: true

module Emcp
  module Servers
    module Browser
      class Client
        EVAL_TOOL = "browser_eval_readonly"

        def initialize(server)
          @server = server
        end

        def call(tool, args = {}, write: false)
          policy = origin_policy
          arguments = args.to_h.transform_keys(&:to_s)
          ensure_allowed!(policy, tool, arguments)
          ensure_eval!(tool)

          reply = registry.dispatch(
            @server.id,
            {
              "tool" => tool,
              "args" => arguments,
              "write" => write,
              "allowed_origins" => policy.origins,
              "allow_eval" => eval_allowed?,
              "max_chars" => max_chars,
            },
            timeout: timeout,
          )
          raise reply["error"].to_s if reply["ok"] == false

          result = reply["result"]
          if tool == "browser_list_tabs" && result.is_a?(Hash)
            result = { "tabs" => policy.filter_tabs(result["tabs"]) }
          elsif result.is_a?(Hash) && result["url"].present? && !policy.allows_url?(result["url"])
            raise "Origin is not on the allowlist"
          end
          result
        end

        private

        def registry = SessionRegistry.current

        def origin_policy
          raw = @server.credentials_hash["BROWSER_ALLOWED_ORIGINS"].presence ||
            ENV["BROWSER_ALLOWED_ORIGINS"].presence ||
            OriginPolicy::DEFAULT
          OriginPolicy.new(raw)
        end

        def ensure_allowed!(policy, tool, arguments)
          return unless OriginPolicy::PAGE_TOOLS.include?(tool)
          raise "Allowed origins did not match any Chrome pattern" if policy.empty?
          return unless OriginPolicy::URL_TOOLS.include?(tool)

          url = arguments["url"]
          raise "Origin is not on the allowlist" unless policy.allows_url?(url)
        end

        def ensure_eval!(tool)
          return unless tool == EVAL_TOOL
          raise "browser_eval_readonly is disabled. Set BROWSER_ALLOW_EVAL=true" unless eval_allowed?
        end

        def eval_allowed?
          ActiveModel::Type::Boolean.new.cast(
            ENV.fetch("BROWSER_ALLOW_EVAL") { Emcp.server_setting("browser", "allow_eval", false) },
          )
        end

        def timeout
          raw = ENV["BROWSER_TIMEOUT"].presence || Emcp.server_setting("browser", "timeout", 30)
          seconds = raw.to_i
          seconds.positive? ? seconds : 30
        end

        def max_chars
          raw = Emcp.server_setting("browser", "max_chars", 12_000).to_i
          raw.positive? ? raw : 12_000
        end
      end
    end
  end
end
