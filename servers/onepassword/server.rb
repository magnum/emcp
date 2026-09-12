# frozen_string_literal: true

require_relative "onepassword_client"

module Emcp
  module Servers
    module OnePassword
      class Server < ::McpServer
        server_id "onepassword"
        display_name "1Password"
        description "Vaults, items, documents, and secret references through the 1Password CLI (op), authenticated with a service account token."
        version "0.1.0"

        def instructions
          "Use 1Password tools to read vaults and items via the official `op` CLI. " \
            "Authenticate with OP_SERVICE_ACCOUNT_TOKEN (no desktop app). " \
            "Prefer vault and item IDs over names — service accounts are rate-limited and " \
            "item/document commands should pass --vault when the account can see more than one vault. " \
            "Secret references look like op://vault/item/field (optional section). " \
            "Service accounts cannot access Personal, Private, Employee, or the default Shared vault. " \
            "Write tools stay disabled unless ONEPASSWORD_ALLOW_WRITE=true. " \
            "Never echo the service account token."
        end

        def auth_help_content
          {
            title: "Connect 1Password with a service account token",
            description: "EmCP runs `op` headless on the server. Paste a 1Password Service Account " \
                         "token so the CLI can authenticate without the desktop app or biometrics. " \
                         "See https://www.1password.dev/service-accounts/use-with-1password-cli " \
                         "and https://www.1password.dev/cli",
            steps: [
              "On 1Password.com go to Developer → create a Service Account (CLI 2.18+).",
              "Grant only the vaults EmCP should see (read_items, plus write_items if you will enable writes).",
              "You cannot grant Personal, Private, Employee, or the default Shared vault.",
              "Save the token when it is shown (it is displayed once), then paste it below.",
              "Optional: create the token with `op service-account create` on a trusted machine.",
            ],
            commands: [
              {
                label: "Create a read-only service account (on a trusted computer)",
                value: 'op service-account create "EmCP" --vault "Production:read_items"',
              },
              {
                label: "Verify the token with the CLI",
                value: 'export OP_SERVICE_ACCOUNT_TOKEN="ops_…" && op user get --me',
              },
            ],
            note: "Treat the token like a password and paste it only over HTTPS. " \
                  "OP_CONNECT_HOST / OP_CONNECT_TOKEN take precedence over a service account — " \
                  "EmCP clears those for `op` so the pasted token is used. " \
                  "Writes need ONEPASSWORD_ALLOW_WRITE=true and write_items on the service account.",
          }
        end

        def auth_fields
          [
            {
              name: "op_service_account_token",
              label: "1Password service account token",
              type: "password",
              required: false,
              help: "Token from Developer → Service Accounts (starts with ops_). Leave blank to keep a saved token.",
              env: "OP_SERVICE_ACCOUNT_TOKEN",
            },
          ]
        end

        def auth_status_cache_ttl = 120

        def fetch_auth_status
          load_credentials!
          unless @client.configured?
            return { authenticated: false, error: "OP_SERVICE_ACCOUNT_TOKEN is not configured" }
          end

          raw = @client.run(@client.whoami, truncate: false)
          data = parse_json_object(raw)
          {
            authenticated: true,
            account_type: data["type"],
            state: data["state"],
            name: data["name"],
            user_id: data["id"],
          }
        rescue StandardError => e
          {
            authenticated: false,
            error: e.message,
          }
        end

        def apply_credentials(params)
          load_credentials!
          token = Emcp.sanitize_env_value(params["op_service_account_token"])
          effective = token.presence || Emcp.sanitize_env_value(ENV["OP_SERVICE_ACCOUNT_TOKEN"])
          raise "OP_SERVICE_ACCOUNT_TOKEN is required" if effective.empty?

          apply_credentials_probe!(
            { "OP_SERVICE_ACCOUNT_TOKEN" => effective },
            rejection_message: "1Password service account token was rejected",
          )
        ensure
          token = nil
          effective = nil
        end

        def clear_credentials!
          persist_credentials!("OP_SERVICE_ACCOUNT_TOKEN" => nil)
          replace_client!
        end

        def configure_tools
          define_account_tools
          define_vault_tools
          define_item_tools
          define_secret_tools
          define_document_tools
        end

        def replace_client!
          @client = Client.new
        end

        def credential_env_keys = %w[OP_SERVICE_ACCOUNT_TOKEN]

        private

        def define_account_tools
          define_tool(
            name: "onepassword_whoami",
            description: "Show the authenticated 1Password service account (`op user get --me`).",
          ) { cli_response(@client, @client.whoami) }

          define_tool(
            name: "onepassword_ratelimit",
            description: "Show hourly and daily request quota usage for the service account.",
          ) { cli_response(@client, @client.ratelimit) }
        end

        def define_vault_tools
          define_tool(
            name: "onepassword_vault_list",
            description: "List vaults the service account can access.",
          ) { cli_response(@client, @client.vault_list) }

          define_tool(
            name: "onepassword_vault_get",
            description: "Get one vault by name or ID. Prefer the vault ID to use fewer API requests.",
            properties: { vault: string_prop("Vault name or ID") },
            required: ["vault"],
          ) { |vault:| cli_response(@client, @client.vault_get(vault)) }

          define_tool(
            name: "onepassword_vault_create",
            description: "Create a vault (write). The service account must be allowed to create vaults.",
            properties: { name: string_prop("New vault name") },
            required: ["name"],
            write: true,
          ) { |name:| cli_response(@client, @client.vault_create(name)) }

          define_tool(
            name: "onepassword_vault_delete",
            description: "Delete a vault the service account created (write).",
            properties: { vault: string_prop("Vault name or ID") },
            required: ["vault"],
            write: true,
          ) { |vault:| cli_response(@client, @client.vault_delete(vault)) }
        end

        def define_item_tools
          define_tool(
            name: "onepassword_item_list",
            description: "List items. Pass vault (ID preferred) when the service account can see more than one vault.",
            properties: {
              vault: string_prop("Vault name or ID (recommended)"),
              categories: string_prop("Optional comma-separated categories, e.g. LOGIN,PASSWORD"),
              tags: string_prop("Optional comma-separated tags"),
              include_archive: boolean_prop("Include archived items"),
            },
          ) do |vault: nil, categories: nil, tags: nil, include_archive: false|
            cli_response(
              @client,
              @client.item_list(
                vault: vault,
                categories: categories,
                tags: tags,
                include_archive: include_archive,
              ),
            )
          end

          define_tool(
            name: "onepassword_item_get",
            description: "Get one item (fields revealed). Prefer item and vault IDs. " \
                         "Optional fields is a comma-separated list (e.g. label=username,label=password).",
            properties: {
              item: string_prop("Item name or ID"),
              vault: string_prop("Vault name or ID (recommended)"),
              fields: string_prop("Optional field filter for `op item get --fields`"),
            },
            required: ["item"],
          ) do |item:, vault: nil, fields: nil|
            cli_response(@client, @client.item_get(item, vault: vault, fields: fields))
          end

          define_tool(
            name: "onepassword_item_create",
            description: "Create an item (write). Assignments use CLI syntax, e.g. username=ada password=secret.",
            properties: {
              title: string_prop("Item title"),
              category: string_prop("Item category, e.g. LOGIN, PASSWORD, SECURE_NOTE, API_CREDENTIAL"),
              vault: string_prop("Vault name or ID"),
              assignments: array_prop("Field assignments (key=value)"),
              generate_password: boolean_prop("Ask the CLI to generate a password"),
            },
            required: %w[title category vault],
            write: true,
          ) do |title:, category:, vault:, assignments: nil, generate_password: false|
            cli_response(
              @client,
              @client.item_create(
                title: title,
                category: category,
                vault: vault,
                assignments: assignments,
                generate_password: generate_password,
              ),
            )
          end

          define_tool(
            name: "onepassword_item_edit",
            description: "Edit an item (write). Assignments use CLI syntax (key=value).",
            properties: {
              item: string_prop("Item name or ID"),
              vault: string_prop("Vault name or ID"),
              assignments: array_prop("Field assignments to change"),
            },
            required: %w[item vault],
            write: true,
          ) do |item:, vault:, assignments: nil|
            cli_response(@client, @client.item_edit(item, vault: vault, assignments: assignments))
          end

          define_tool(
            name: "onepassword_item_delete",
            description: "Delete an item (write).",
            properties: {
              item: string_prop("Item name or ID"),
              vault: string_prop("Vault name or ID"),
            },
            required: %w[item vault],
            write: true,
          ) do |item:, vault:|
            cli_response(@client, @client.item_delete(item, vault: vault))
          end
        end

        def define_secret_tools
          define_tool(
            name: "onepassword_read",
            description: "Resolve one secret reference (`op read`), e.g. op://vault-id/item-id/password. " \
                         "IDs use fewer service-account requests than names.",
            properties: {
              reference: string_prop("Secret reference starting with op://"),
            },
            required: ["reference"],
          ) do |reference:|
            ref = reference.to_s.strip
            unless ref.start_with?("op://")
              next text_response("ERROR: reference must start with op://")
            end

            cli_response(@client, @client.read_reference(ref))
          end
        end

        def define_document_tools
          define_tool(
            name: "onepassword_document_list",
            description: "List document items. Pass vault when the service account can see more than one vault.",
            properties: {
              vault: string_prop("Vault name or ID (recommended)"),
            },
          ) { |vault: nil| cli_response(@client, @client.document_list(vault: vault)) }

          define_tool(
            name: "onepassword_document_get",
            description: "Download a document's contents to the tool output (`op document get --output=-`).",
            properties: {
              document: string_prop("Document name or ID"),
              vault: string_prop("Vault name or ID (recommended)"),
            },
            required: ["document"],
          ) do |document:, vault: nil|
            cli_response(@client, @client.document_get(document, vault: vault))
          end
        end

        def parse_json_object(raw)
          data = JSON.parse(raw)
          raise "1Password whoami returned a non-object" unless data.is_a?(Hash)

          data
        rescue JSON::ParserError => e
          raise "invalid 1Password CLI JSON: #{e.message}"
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::OnePassword::Server)
