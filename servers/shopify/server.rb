# frozen_string_literal: true

require "openssl"
require_relative "shopify_client"

module Emcp
  module Servers
    module Shopify
      class Server < ::McpServer
        server_id "shopify"
        display_name "Shopify"
        description "Manage one Shopify store through the GraphQL Admin API. Create one instance per store."
        version "0.1.0"
        oauth_token_retrieval true

        # Expiring offline tokens are refreshed on 401; this keeps them warm.
        def self.default_service_token_refresh_in_minutes = 60

        DEFAULT_READ_SCOPES = %w[read_products read_orders read_inventory read_locations read_content].freeze
        DEFAULT_WRITE_SCOPES = %w[write_products write_orders write_inventory write_content].freeze

        def instructions
          "This instance is one Shopify store (SHOPIFY_SHOP). " \
            "Use shopify_shop, shopify_products, shopify_orders, and shopify_locations to read it. " \
            "Use shopify_graphql for any other Admin API operation. " \
            "Mutations stay disabled unless SHOPIFY_ALLOW_WRITE=true. " \
            "Create another EmCP instance to manage a second store."
        end

        def auth_help_content
          {
            title: "Authorize a Shopify store",
            description: "Create a Shopify app in the Dev Dashboard and install it on a store you can access. " \
                         "Each EmCP instance holds one store.",
            steps: [
              "In the Shopify Dev Dashboard, create an app and copy the client ID and client secret.",
              "Add the callback URL shown below as an allowed redirect URL.",
              "Enter the store as *.myshopify.com (for example cool-store.myshopify.com).",
              "App scopes: the read scopes below. Add the write scopes when SHOPIFY_ALLOW_WRITE=true.",
              "Choose Retrieve OAuth token and approve the app on that store.",
            ],
            commands: [],
            note: "Tokens are stored under storage/mcp/instances/<id>/oauth_token.json. " \
                  "EmCP requests expiring offline tokens and refreshes them. " \
                  "See https://shopify.dev/docs/apps/build/authentication-authorization/get-access-tokens/auth-code-grant.",
          }
        end

        def auth_fields
          [
            {
              name: "shopify_shop",
              label: "Store domain",
              type: "text",
              required: true,
              oauth_app: true,
              help: "The *.myshopify.com domain of the store you can access.",
              env: "SHOPIFY_SHOP",
            },
            {
              name: "shopify_client_id",
              label: "Client ID",
              type: "text",
              required: true,
              oauth_app: true,
              help: "From the Shopify app in the Dev Dashboard.",
              env: "SHOPIFY_CLIENT_ID",
            },
            {
              name: "shopify_client_secret",
              label: "Client secret",
              type: "password",
              required: true,
              oauth_app: true,
              help: "Leave blank to keep a saved secret.",
              env: "SHOPIFY_CLIENT_SECRET",
            },
            {
              name: "shopify_token",
              label: "Access token",
              type: "password",
              required: false,
              help: "Filled by Retrieve OAuth token. Leave blank when saving to keep the current token.",
              env: "SHOPIFY_TOKEN",
            },
          ]
        end

        def auth_status_cache_ttl = 120

        def emcp_service_info
          fetch_auth_status
        end

        def fetch_auth_status
          result = @client.graphql("{ shop { name myshopifyDomain } }")
          shop = result.dig(:body, "data", "shop") || {}
          {
            authenticated: result[:status].between?(200, 299) && shop["name"].present?,
            shop: shop["myshopifyDomain"],
            name: shop["name"],
          }
        rescue StandardError => e
          { authenticated: false, error: e.message }
        end

        def prepare_provider_oauth!(params)
          persist_oauth_app_credentials!(params)
          load_credentials!
          replace_client!
        end

        def apply_credentials(params)
          load_credentials!
          token = Emcp.sanitize_env_value(params["shopify_token"])
          updates = oauth_app_credential_updates(params)
          updates["SHOPIFY_TOKEN"] = token if token.present?
          effective = updates["SHOPIFY_TOKEN"].presence || Emcp.sanitize_env_value(ENV["SHOPIFY_TOKEN"])
          raise "Shopify access token is required" if effective.empty?

          apply_credentials_probe!(
            updates.merge("SHOPIFY_TOKEN" => effective),
            rejection_message: "Shopify token was rejected",
          )
        ensure
          token = nil
        end

        def clear_credentials!
          clear_oauth_token_file!
          persist_credentials!(
            "SHOPIFY_TOKEN" => nil,
            "SHOPIFY_REFRESH_TOKEN" => nil,
          )
          replace_client!
        end

        def oauth_call(callback_url:, state:)
          raise "SHOPIFY_CLIENT_ID is required" if Emcp.sanitize_env_value(ENV["SHOPIFY_CLIENT_ID"]).empty?
          Client.shop_domain

          {
            authorization_url: Client.authorization_url(
              callback_url: callback_url,
              state: state,
              scopes: oauth_scopes,
            ),
          }
        end

        def oauth_exchange(callback_url:, params:, state_data: nil)
          raise "OAuth callback did not include a code" if params["code"].to_s.empty?

          secret = Emcp.sanitize_env_value(ENV["SHOPIFY_CLIENT_SECRET"])
          unless Client.valid_hmac?(params, secret: secret)
            raise "Shopify callback HMAC is invalid"
          end

          shop = Client.shop_domain(params["shop"])
          persist_credentials!("SHOPIFY_SHOP" => shop)

          @client.exchange_authorization_code(code: params["code"])
        end

        def configure_tools
          define_tool(
            name: "shopify_shop",
            description: "Return the connected store name, domain, currency, and plan.",
          ) do
            api_response(@client.graphql(<<~GRAPHQL))
              { shop { name myshopifyDomain email currencyCode plan { displayName } } }
            GRAPHQL
          end

          define_tool(
            name: "shopify_products",
            description: "List products on the connected store.",
            properties: {
              first: integer_prop("Page size, default 20, maximum 50."),
              query: string_prop("Shopify product search query, such as title:shirt or status:active."),
            },
          ) do |first: 20, query: nil|
            api_response(@client.graphql(
              <<~GRAPHQL,
                query Products($first: Int!, $query: String) {
                  products(first: $first, query: $query) {
                    nodes { id title handle status totalInventory }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              GRAPHQL
              variables: { first: page_size(first), query: query.presence },
            ))
          end

          define_tool(
            name: "shopify_orders",
            description: "List orders on the connected store.",
            properties: {
              first: integer_prop("Page size, default 20, maximum 50."),
              query: string_prop("Shopify order search query, such as financial_status:paid."),
            },
          ) do |first: 20, query: nil|
            api_response(@client.graphql(
              <<~GRAPHQL,
                query Orders($first: Int!, $query: String) {
                  orders(first: $first, query: $query, sortKey: CREATED_AT, reverse: true) {
                    nodes { id name createdAt displayFinancialStatus displayFulfillmentStatus }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              GRAPHQL
              variables: { first: page_size(first), query: query.presence },
            ))
          end

          define_tool(
            name: "shopify_locations",
            description: "List inventory locations on the connected store.",
          ) do
            api_response(@client.graphql(<<~GRAPHQL))
              { locations(first: 50) { nodes { id name isActive } } }
            GRAPHQL
          end

          define_tool(
            name: "shopify_graphql",
            description: "Run a GraphQL Admin API operation on the connected store. " \
                         "Mutations require SHOPIFY_ALLOW_WRITE=true. API version #{Client::API_VERSION}.",
            properties: {
              query: string_prop("GraphQL query or mutation."),
              variables: object_prop("Optional GraphQL variables."),
            },
            required: ["query"],
          ) do |query:, variables: nil|
            document = query.to_s
            raise "query is empty" if document.strip.empty?
            if document.match?(/\bmutation\b/) && !allow_write_methods?
              raise "write method disabled"
            end

            vars = variables.nil? ? nil : require_object(variables)
            api_response(@client.graphql(document, variables: vars))
          end
        end

        def refresh_service_token!
          load_credentials!
          replace_client!
          @client.refresh_access_token!
        end

        def credential_env_keys
          %w[
            SHOPIFY_SHOP
            SHOPIFY_CLIENT_ID
            SHOPIFY_CLIENT_SECRET
            SHOPIFY_TOKEN
            SHOPIFY_REFRESH_TOKEN
          ]
        end

        def oauth_access_env = "SHOPIFY_TOKEN"
        def oauth_refresh_env = "SHOPIFY_REFRESH_TOKEN"

        def replace_client!
          @client = Client.new(on_token_refresh: method(:persist_refreshed_token!))
        end

        private

        def oauth_scopes
          custom = Emcp.sanitize_env_value(ENV["SHOPIFY_OAUTH_SCOPES"])
          return custom if custom.present?

          scopes = DEFAULT_READ_SCOPES.dup
          scopes.concat(DEFAULT_WRITE_SCOPES) if allow_write_methods?
          scopes.join(",")
        end

        def oauth_app_credential_updates(params)
          updates = {}
          {
            "shopify_shop" => "SHOPIFY_SHOP",
            "shopify_client_id" => "SHOPIFY_CLIENT_ID",
            "shopify_client_secret" => "SHOPIFY_CLIENT_SECRET",
          }.each do |form_key, env_key|
            value = Emcp.sanitize_env_value(params[form_key])
            updates[env_key] = value if value.present?
          end
          if updates["SHOPIFY_SHOP"].present?
            updates["SHOPIFY_SHOP"] = Client.shop_domain(updates["SHOPIFY_SHOP"])
          end
          updates
        end

        def persist_oauth_app_credentials!(params)
          updates = oauth_app_credential_updates(params)
          persist_credentials!(updates) if updates.any?
        end

        def persist_refreshed_token!(access_token:, refresh_token:, body:)
          persist_refreshed_oauth_token!(
            access_token: access_token,
            refresh_token: refresh_token,
            body: body,
          )
        end

        def page_size(value)
          size = value.to_i
          size = 20 if size <= 0
          [size, 50].min
        end

        def require_object(value)
          raise "variables must be a JSON object" unless value.is_a?(Hash)

          value
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::Shopify::Server)
