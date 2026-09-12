# frozen_string_literal: true

require "fileutils"

module Emcp
  module Servers
    module OnePassword
      class Client < CliClient
        def initialize
          super(
            bin: ENV.fetch("OP_BIN", "op"),
            timeout: ENV.fetch("OP_TIMEOUT", "45").to_i,
            max_chars: ENV.fetch("EMCP_MAX_CHARS", "100000").to_i,
            env: {},
          )
        end

        def run(args, truncate: true)
          @env = cli_env
          super
        rescue Emcp::CliError => e
          raise Emcp::CliError, redact(e.message)
        end

        def configured?
          token.present?
        end

        def token
          Emcp.sanitize_env_value(ENV["OP_SERVICE_ACCOUNT_TOKEN"])
        end

        def whoami = json("user", "get", "--me")
        def ratelimit = json("service-account", "ratelimit")

        def vault_list = json("vault", "list")
        def vault_get(vault) = json("vault", "get", vault)
        def vault_create(name) = json("vault", "create", name)
        def vault_delete(vault) = json("vault", "delete", vault)

        def item_list(vault: nil, categories: nil, tags: nil, include_archive: false)
          json(
            "item", "list",
            *flag("--vault", vault),
            *flag("--categories", categories),
            *flag("--tags", tags),
            *(include_archive ? ["--include-archive"] : []),
          )
        end

        def item_get(item, vault: nil, fields: nil, reveal: true)
          json(
            "item", "get", item,
            *flag("--vault", vault),
            *flag("--fields", fields),
            *(reveal ? ["--reveal"] : []),
          )
        end

        def item_create(title:, category:, vault:, assignments: [], generate_password: false)
          json(
            "item", "create",
            *flag("--title", title),
            *flag("--category", category),
            *flag("--vault", vault),
            *(generate_password ? ["--generate-password"] : []),
            *Array(assignments).map(&:to_s).reject(&:empty?),
          )
        end

        def item_edit(item, vault:, assignments: [])
          json(
            "item", "edit", item,
            *flag("--vault", vault),
            *Array(assignments).map(&:to_s).reject(&:empty?),
          )
        end

        def item_delete(item, vault:)
          json("item", "delete", item, *flag("--vault", vault))
        end

        def read_reference(reference)
          ["read", reference.to_s]
        end

        def document_list(vault: nil)
          json("document", "list", *flag("--vault", vault))
        end

        def document_get(document, vault: nil)
          [
            "document", "get", document,
            *flag("--vault", vault),
            "--output=-",
          ]
        end

        private

        def json(*parts) = [*parts, "--format=json"]

        def flag(name, value)
          cleaned = value.to_s.strip
          cleaned.empty? ? [] : [name, cleaned]
        end

        def cli_env
          {
            "OP_SERVICE_ACCOUNT_TOKEN" => token,
            "OP_CONNECT_HOST" => nil,
            "OP_CONNECT_TOKEN" => nil,
            "OP_CACHE" => "false",
            "OP_CONFIG_DIR" => config_dir,
          }
        end

        def config_dir
          path = ENV.fetch("OP_CONFIG_DIR") do
            Rails.root.join("storage", "mcp", "onepassword", "config").to_s
          end
          FileUtils.mkdir_p(path)
          path
        end

        def redact(text)
          secret = token
          return text.to_s if secret.empty?

          text.to_s.gsub(secret, "[REDACTED]")
        end
      end
    end
  end
end
