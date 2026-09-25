# frozen_string_literal: true

require_relative "microsoftgraph_client"

module Emcp
  module Servers
    module MicrosoftGraph
      class Server < ::McpServer
        server_id "microsoftgraph"
        display_name "Microsoft Graph"
        description "Microsoft Graph v1.0, including SharePoint site, list, and list-item updates."
        version "0.1.0"
        oauth_token_retrieval true

        # Access tokens last about 60–90 minutes.
        def self.default_service_token_refresh_in_minutes = 50

        DEFAULT_READ_SCOPES = %w[offline_access User.Read Sites.Read.All].freeze
        DEFAULT_WRITE_SCOPES = %w[Sites.ReadWrite.All].freeze

        def instructions
          "Use Microsoft Graph tools to read the signed-in user and SharePoint sites. " \
            "Site, list, and list-item mutations stay disabled unless MICROSOFTGRAPH_ALLOW_WRITE=true. " \
            "Site tools use site_id, or hostname plus path, or the saved MICROSOFTGRAPH_SITE_ID. " \
            "Graph calls use https://graph.microsoft.com/v1.0."
        end

        def auth_help_content
          {
            title: "Authorize Microsoft Graph",
            description: "Register a confidential Entra app and complete the OAuth code flow in this form. " \
                         "SharePoint edits need Sites.ReadWrite.All and admin consent in many tenants.",
            steps: [
              "In Microsoft Entra, register an app (Accounts in any organizational directory, or your tenant only).",
              "Add a Web redirect URI equal to the callback URL shown below.",
              "Create a client secret and paste the Application (client) ID and secret here.",
              "Set the Directory (tenant) ID, or leave the tenant as organizations.",
              "API permissions: delegated offline_access, User.Read, Sites.Read.All. " \
                "Add Sites.ReadWrite.All when MICROSOFTGRAPH_ALLOW_WRITE=true, then grant admin consent.",
              "Choose Retrieve OAuth token. Optionally set a default SharePoint hostname and site path.",
            ],
            commands: [],
            note: "Tokens are stored under storage/mcp/instances/<id>/oauth_token.json. " \
                  "Access tokens are refreshed with the refresh token. " \
                  "See https://learn.microsoft.com/en-us/graph/use-the-api.",
          }
        end

        def auth_fields
          [
            {
              name: "microsoftgraph_tenant_id",
              label: "Directory (tenant) ID",
              type: "text",
              required: false,
              oauth_app: true,
              help: "Tenant GUID, or organizations / common. Blank uses organizations.",
              env: "MICROSOFTGRAPH_TENANT_ID",
            },
            {
              name: "microsoftgraph_client_id",
              label: "Application (client) ID",
              type: "text",
              required: true,
              oauth_app: true,
              help: "From the Entra app registration.",
              env: "MICROSOFTGRAPH_CLIENT_ID",
            },
            {
              name: "microsoftgraph_client_secret",
              label: "Client secret",
              type: "password",
              required: true,
              oauth_app: true,
              help: "Leave blank to keep a saved secret.",
              env: "MICROSOFTGRAPH_CLIENT_SECRET",
            },
            {
              name: "microsoftgraph_token",
              label: "Access token",
              type: "password",
              required: false,
              help: "Filled by Retrieve OAuth token. Leave blank when saving to keep the current token.",
              env: "MICROSOFTGRAPH_TOKEN",
            },
            {
              name: "microsoftgraph_site_hostname",
              label: "Default SharePoint hostname",
              type: "text",
              required: false,
              help: "Example: contoso.sharepoint.com. Used when a tool omits hostname.",
              env: "MICROSOFTGRAPH_SITE_HOSTNAME",
            },
            {
              name: "microsoftgraph_site_path",
              label: "Default site path",
              type: "text",
              required: false,
              help: "Server-relative path without a leading slash, such as sites/Marketing.",
              env: "MICROSOFTGRAPH_SITE_PATH",
            },
            {
              name: "microsoftgraph_site_id",
              label: "Default site ID",
              type: "text",
              required: false,
              help: "Graph site id. When set, site tools use it instead of hostname and path.",
              env: "MICROSOFTGRAPH_SITE_ID",
            },
          ]
        end

        def auth_status_cache_ttl = 120

        def fetch_auth_status
          result = @client.get("/me", query: { "$select" => "id,displayName,userPrincipalName" })
          body = result[:body].is_a?(Hash) ? result[:body] : {}
          {
            authenticated: result[:status].between?(200, 299),
            display_name: body["displayName"],
            user_principal_name: body["userPrincipalName"],
            site_id: Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_SITE_ID"]),
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
          token = Emcp.sanitize_env_value(params["microsoftgraph_token"])
          updates = oauth_app_credential_updates(params)
          updates["MICROSOFTGRAPH_TOKEN"] = token if token.present?
          %w[site_hostname site_path site_id].each do |suffix|
            key = "microsoftgraph_#{suffix}"
            env_key = "MICROSOFTGRAPH_#{suffix.upcase}"
            next unless params.key?(key)

            value = Emcp.sanitize_env_value(params[key])
            updates[env_key] = value if value.present?
          end
          effective = updates["MICROSOFTGRAPH_TOKEN"].presence || Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_TOKEN"])
          raise "Microsoft Graph access token is required" if effective.empty?

          apply_credentials_probe!(
            updates.merge("MICROSOFTGRAPH_TOKEN" => effective),
            rejection_message: "Microsoft Graph token was rejected",
          )
        ensure
          token = nil
        end

        def clear_credentials!
          clear_oauth_token_file!
          persist_credentials!(
            "MICROSOFTGRAPH_TOKEN" => nil,
            "MICROSOFTGRAPH_REFRESH_TOKEN" => nil,
            "MICROSOFTGRAPH_SITE_HOSTNAME" => nil,
            "MICROSOFTGRAPH_SITE_PATH" => nil,
            "MICROSOFTGRAPH_SITE_ID" => nil,
          )
          replace_client!
        end

        def oauth_call(callback_url:, state:)
          client_id = Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_CLIENT_ID"])
          raise "MICROSOFTGRAPH_CLIENT_ID is required" if client_id.empty?

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

          @client.exchange_authorization_code(callback_url: callback_url, code: params["code"])
        end

        def configure_tools
          define_identity_tools
          define_site_tools
          define_list_tools
          define_drive_tools
          define_request_tool
        end

        def refresh_service_token!
          load_credentials!
          replace_client!
          @client.refresh_access_token!
        end

        def credential_env_keys
          %w[
            MICROSOFTGRAPH_TENANT_ID
            MICROSOFTGRAPH_CLIENT_ID
            MICROSOFTGRAPH_CLIENT_SECRET
            MICROSOFTGRAPH_TOKEN
            MICROSOFTGRAPH_REFRESH_TOKEN
            MICROSOFTGRAPH_SITE_HOSTNAME
            MICROSOFTGRAPH_SITE_PATH
            MICROSOFTGRAPH_SITE_ID
          ]
        end

        def oauth_access_env = "MICROSOFTGRAPH_TOKEN"
        def oauth_refresh_env = "MICROSOFTGRAPH_REFRESH_TOKEN"

        def replace_client!
          @client = Client.new(on_token_refresh: method(:persist_refreshed_token!))
        end

        private

        def oauth_scopes
          custom = Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_OAUTH_SCOPES"])
          return custom if custom.present?

          scopes = DEFAULT_READ_SCOPES.dup
          scopes.concat(DEFAULT_WRITE_SCOPES) if allow_write_methods?
          scopes.join(" ")
        end

        def oauth_app_credential_updates(params)
          updates = {}
          {
            "microsoftgraph_tenant_id" => "MICROSOFTGRAPH_TENANT_ID",
            "microsoftgraph_client_id" => "MICROSOFTGRAPH_CLIENT_ID",
            "microsoftgraph_client_secret" => "MICROSOFTGRAPH_CLIENT_SECRET",
          }.each do |form_key, env_key|
            value = Emcp.sanitize_env_value(params[form_key])
            updates[env_key] = value if value.present?
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

        def define_identity_tools
          define_tool(
            name: "microsoftgraph_me",
            description: "Return the signed-in Microsoft 365 user (GET /me).",
          ) { api_response(@client.get("/me", query: { "$select" => "id,displayName,userPrincipalName,mail" })) }
        end

        def define_site_tools
          site_props = {
            site_id: string_prop("Graph site id. Defaults to MICROSOFTGRAPH_SITE_ID."),
            hostname: string_prop("SharePoint hostname, such as contoso.sharepoint.com."),
            path: string_prop("Site path without a leading slash, such as sites/Marketing."),
          }
          define_tool(
            name: "microsoftgraph_sites_search",
            description: "Search SharePoint sites the signed-in user can access (GET /sites?search=).",
            properties: { query: string_prop("Search text. Use * to list sites the app can see.") },
            required: ["query"],
          ) do |query:|
            api_response(@client.get("/sites", query: { search: query }))
          end

          define_tool(
            name: "microsoftgraph_site",
            description: "Get one SharePoint site by id, or by hostname and path.",
            properties: site_props,
          ) do |site_id: nil, hostname: nil, path: nil|
            api_response(@client.get(resolve_site_path(site_id:, hostname:, path:)))
          end

          define_tool(
            name: "microsoftgraph_site_update",
            description: "Update a SharePoint site display name and description (PATCH /sites/{id}).",
            properties: site_props.merge(
              display_name: string_prop("New site display name."),
              description: string_prop("New site description."),
            ),
            write: true,
          ) do |site_id: nil, hostname: nil, path: nil, display_name: nil, description: nil|
            body = compact_hash(displayName: display_name, description: description)
            raise "display_name or description is required" if body.empty?

            id = ensure_site_id(site_id:, hostname:, path:)
            api_response(@client.patch("/sites/#{path_segment(id)}", body: body))
          end
        end

        def define_list_tools
          list_props = {
            site_id: string_prop("Graph site id. Defaults to the configured site."),
            hostname: string_prop("SharePoint hostname when site_id is omitted."),
            path: string_prop("Site path when site_id is omitted."),
            list_id: string_prop("List id or display name."),
          }
          define_tool(
            name: "microsoftgraph_lists",
            description: "List SharePoint lists on a site, including document libraries.",
            properties: list_props.except(:list_id),
          ) do |site_id: nil, hostname: nil, path: nil|
            id = ensure_site_id(site_id:, hostname:, path:)
            api_response(@client.get("/sites/#{path_segment(id)}/lists"))
          end

          define_tool(
            name: "microsoftgraph_list",
            description: "Get one SharePoint list.",
            properties: list_props,
            required: ["list_id"],
          ) do |list_id:, site_id: nil, hostname: nil, path: nil|
            api_response(@client.get(list_path(list_id, site_id:, hostname:, path:)))
          end

          define_tool(
            name: "microsoftgraph_list_update",
            description: "Update a SharePoint list display name or description.",
            properties: list_props.merge(
              display_name: string_prop("New list display name."),
              description: string_prop("New list description."),
            ),
            required: ["list_id"],
            write: true,
          ) do |list_id:, site_id: nil, hostname: nil, path: nil, display_name: nil, description: nil|
            body = compact_hash(displayName: display_name, description: description)
            raise "display_name or description is required" if body.empty?

            api_response(@client.patch(list_path(list_id, site_id:, hostname:, path:), body: body))
          end

          define_tool(
            name: "microsoftgraph_list_items",
            description: "List items in a SharePoint list.",
            properties: list_props.merge(
              top: integer_prop("Page size, sent as $top."),
              select: string_prop("Comma-separated field names, sent as $select."),
            ),
            required: ["list_id"],
          ) do |list_id:, site_id: nil, hostname: nil, path: nil, top: nil, select: nil|
            query = compact_hash("$top" => top, "$expand" => "fields", "$select" => select)
            api_response(@client.get("#{list_path(list_id, site_id:, hostname:, path:)}/items", query: query))
          end

          define_tool(
            name: "microsoftgraph_list_item",
            description: "Get one SharePoint list item, including its fields.",
            properties: list_props.merge(item_id: string_prop("List item id.")),
            required: %w[list_id item_id],
          ) do |list_id:, item_id:, site_id: nil, hostname: nil, path: nil|
            api_response(@client.get(item_path(list_id, item_id, site_id:, hostname:, path:), query: { "$expand" => "fields" }))
          end

          define_tool(
            name: "microsoftgraph_list_item_create",
            description: "Create a SharePoint list item. Pass column values in fields.",
            properties: list_props.merge(fields: object_prop("Column values, for example {\"Title\":\"Hello\"}.")),
            required: %w[list_id fields],
            write: true,
          ) do |list_id:, fields:, site_id: nil, hostname: nil, path: nil|
            api_response(@client.post("#{list_path(list_id, site_id:, hostname:, path:)}/items", body: { fields: require_object(fields, "fields") }))
          end

          define_tool(
            name: "microsoftgraph_list_item_update",
            description: "Update columns on a SharePoint list item (PATCH .../items/{id}/fields).",
            properties: list_props.merge(
              item_id: string_prop("List item id."),
              fields: object_prop("Column values to change."),
            ),
            required: %w[list_id item_id fields],
            write: true,
          ) do |list_id:, item_id:, fields:, site_id: nil, hostname: nil, path: nil|
            api_response(@client.patch("#{item_path(list_id, item_id, site_id:, hostname:, path:)}/fields", body: require_object(fields, "fields")))
          end

          define_tool(
            name: "microsoftgraph_list_item_delete",
            description: "Delete a SharePoint list item.",
            properties: list_props.merge(item_id: string_prop("List item id.")),
            required: %w[list_id item_id],
            write: true,
          ) do |list_id:, item_id:, site_id: nil, hostname: nil, path: nil|
            api_response(@client.delete(item_path(list_id, item_id, site_id:, hostname:, path:)))
          end
        end

        def define_drive_tools
          define_tool(
            name: "microsoftgraph_drives",
            description: "List document libraries (drives) on a SharePoint site.",
            properties: {
              site_id: string_prop("Graph site id."),
              hostname: string_prop("SharePoint hostname when site_id is omitted."),
              path: string_prop("Site path when site_id is omitted."),
            },
          ) do |site_id: nil, hostname: nil, path: nil|
            id = ensure_site_id(site_id:, hostname:, path:)
            api_response(@client.get("/sites/#{path_segment(id)}/drives"))
          end

          define_tool(
            name: "microsoftgraph_drive_children",
            description: "List files and folders in a drive folder. Defaults to the site default drive root.",
            properties: {
              site_id: string_prop("Graph site id."),
              hostname: string_prop("SharePoint hostname when site_id is omitted."),
              path: string_prop("Site path when site_id is omitted."),
              item_id: string_prop("Drive item id. Omit for the root."),
              drive_id: string_prop("Drive id. Omit for the site default drive."),
            },
          ) do |site_id: nil, hostname: nil, path: nil, item_id: nil, drive_id: nil|
            id = ensure_site_id(site_id:, hostname:, path:)
            base = if drive_id.to_s.strip.empty?
                     "/sites/#{path_segment(id)}/drive"
                   else
                     "/sites/#{path_segment(id)}/drives/#{path_segment(drive_id)}"
                   end
            folder = item_id.to_s.strip.empty? ? "root" : "items/#{path_segment(item_id)}"
            api_response(@client.get("#{base}/#{folder}/children"))
          end
        end

        def define_request_tool
          define_tool(
            name: "microsoftgraph_request",
            description: "Call another Microsoft Graph v1.0 path. Non-GET methods are write tools. " \
                         "The path is relative to https://graph.microsoft.com/v1.0.",
            properties: {
              method: string_prop("HTTP method: GET, POST, PATCH, PUT, or DELETE."),
              path: string_prop("Path beginning with /, such as /sites/{id}/pages."),
              query: object_prop("Optional query parameters."),
              body: object_prop("JSON body for POST, PATCH, and PUT."),
            },
            required: %w[method path],
            write: false,
          ) do |method:, path:, query: nil, body: nil|
            verb = method.to_s.strip.downcase
            raise "method must be GET, POST, PATCH, PUT, or DELETE" unless %w[get post patch put delete].include?(verb)
            raise "write method disabled" if verb != "get" && !allow_write_methods?

            query_hash = query.nil? ? {} : require_object(query, "query")
            payload = body.nil? ? nil : require_object(body, "body")
            result = case verb
                     when "get" then @client.get(path, query: query_hash)
                     when "delete" then @client.delete(path, query: query_hash)
                     else @client.public_send(verb, path, query: query_hash, body: payload || {})
                     end
            api_response(result)
          end
        end

        def resolve_site_path(site_id:, hostname:, path:)
          id = site_id.to_s.strip
          id = Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_SITE_ID"]) if id.empty?
          return "/sites/#{path_segment(id)}" if id.present?

          host = hostname.to_s.strip
          host = Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_SITE_HOSTNAME"]) if host.empty?
          relative = path.to_s.strip.sub(%r{\A/+}, "")
          relative = Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_SITE_PATH"]).sub(%r{\A/+}, "") if relative.empty?
          raise "site_id, or hostname and path, is required" if host.empty? || relative.empty?
          raise "hostname is not valid" unless host.match?(/\A[A-Za-z0-9][A-Za-z0-9.-]+\z/)

          "/sites/#{host}:/#{relative}"
        end

        def ensure_site_id(site_id:, hostname:, path:)
          id = site_id.to_s.strip
          id = Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_SITE_ID"]) if id.empty?
          return id if id.present?

          result = @client.get(resolve_site_path(site_id: nil, hostname: hostname, path: path))
          body = result[:body].is_a?(Hash) ? result[:body] : {}
          found = body["id"].to_s
          raise "SharePoint site lookup did not return an id" if found.empty?

          found
        end

        def list_path(list_id, site_id:, hostname:, path:)
          id = ensure_site_id(site_id:, hostname:, path:)
          "/sites/#{path_segment(id)}/lists/#{path_segment(list_id)}"
        end

        def item_path(list_id, item_id, site_id:, hostname:, path:)
          "#{list_path(list_id, site_id:, hostname:, path:)}/items/#{path_segment(item_id)}"
        end

        def path_segment(value)
          segment = value.to_s.strip
          raise "path segment is empty" if segment.empty?
          raise "path segment is not valid" if segment.include?("/") || segment.include?("..")

          URI.encode_www_form_component(segment)
        end

        def require_object(value, label)
          raise "#{label} must be a JSON object" unless value.is_a?(Hash)

          value
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::MicrosoftGraph::Server)
