# frozen_string_literal: true

require_relative "reminders_client"

module Emcp
  module Servers
    module Reminders
      class Server < ::McpServer
        server_id "reminders"
        display_name "Apple Reminders"
        description "Read and update Apple Reminders through iCloud CalDAV."
        version "0.1.0"

        def instructions
          "Use Apple Reminders tools to read and update iCloud reminder lists over CalDAV. " \
            "This works from the Linux host. It does not open the Reminders app. " \
            "Write tools stay disabled unless allow_write is on for this instance. " \
            "Dates are ISO 8601. Priority follows Apple: 0 is none, 1-4 is high, 5 is medium, 6-9 is low. " \
            "Names none, high, medium, and low write 0, 1, 5, and 9. " \
            "Incomplete reminders are filtered by due date. Completed reminders are filtered by completion date. " \
            "A due filter leaves out reminders that do not have that date. " \
            "Lists upgraded to the current Reminders format are not returned by iCloud CalDAV."
        end

        def auth_help_content
          {
            title: "Connect Apple Reminders",
            description: "EmCP signs in to iCloud CalDAV with an Apple ID and an app-specific password. No Mac is required.",
            steps: [
              "Turn on two-factor authentication for the Apple Account.",
              "Open https://account.apple.com → Sign-In and Security → App-Specific Passwords and generate one for EmCP.",
              "Paste the Apple ID and that password below. Leave the password blank to keep the saved one.",
              "Optional: set a default list. Create uses it when the call omits a list.",
              "Leave Allow write off until you want create, update, and delete.",
            ],
            commands: [
              {
                label: "Discover the iCloud principal",
                value: 'curl -s -X PROPFIND "https://caldav.icloud.com/" -u "$REMINDERS_APPLE_ID:$REMINDERS_APP_PASSWORD" -H "Depth: 0" -H "Content-Type: application/xml" --data \'<propfind xmlns="DAV:"><prop><current-user-principal/></prop></propfind>\'',
              },
            ],
            note: "The password can read iCloud CalDAV for this account. Revoke it at account.apple.com to cut access. Lists upgraded to the current Reminders format do not appear on this API.",
          }
        end

        def auth_fields
          [
            {
              name: "reminders_apple_id",
              label: "Apple ID",
              type: "text",
              required: true,
              help: "The Apple Account email that owns the reminders.",
              env: "REMINDERS_APPLE_ID",
            },
            {
              name: "reminders_app_password",
              label: "App-specific password",
              type: "password",
              required: true,
              help: "From account.apple.com. Leave blank to keep the saved password.",
              env: "REMINDERS_APP_PASSWORD",
            },
            {
              name: "reminders_default_list",
              label: "Default list",
              type: "text",
              required: false,
              help: "Optional. Create uses this list when list_id and list_name are omitted.",
              env: "REMINDERS_DEFAULT_LIST",
            },
            {
              name: "reminders_allow_write",
              label: "Allow write",
              type: "checkbox",
              help: "Create, update, and delete. Saved on this instance.",
              value: -> { allow_write? ? "true" : "false" },
            },
          ]
        end

        def auth_status_cache_ttl = 30

        def emcp_service_info
          fetch_auth_status
        end

        def fetch_auth_status
          load_credentials!
          status = @client.status
          {
            authenticated: true,
            lists: status["lists"],
            default_list: status["default_list"],
            warning: status["warning"],
          }.compact
        rescue StandardError => e
          { authenticated: false, error: e.message }
        end

        def apply_credentials(params)
          load_credentials!
          apple_id = Emcp.sanitize_env_value(params["reminders_apple_id"])
          password = Emcp.sanitize_env_value(params["reminders_app_password"])
          updates = {}
          updates["REMINDERS_APPLE_ID"] = apple_id if apple_id.present?
          updates["REMINDERS_APP_PASSWORD"] = password if password.present?
          if params.key?("reminders_default_list")
            updates["REMINDERS_DEFAULT_LIST"] = Emcp.sanitize_env_value(params["reminders_default_list"])
          end
          effective_id = updates["REMINDERS_APPLE_ID"].presence || Emcp.sanitize_env_value(ENV["REMINDERS_APPLE_ID"])
          effective_password = updates["REMINDERS_APP_PASSWORD"].presence || Emcp.sanitize_env_value(ENV["REMINDERS_APP_PASSWORD"])
          raise "Apple ID is required" if effective_id.empty?
          raise "App-specific password is required" if effective_password.empty?

          apply_credentials_probe!(updates, rejection_message: "iCloud rejected the Apple ID or app-specific password")
          if params.key?("reminders_allow_write")
            update!(allow_write: ActiveModel::Type::Boolean.new.cast(params["reminders_allow_write"]))
          end
          true
        ensure
          password = nil
        end

        def clear_credentials!
          persist_credentials!(
            "REMINDERS_APPLE_ID" => nil,
            "REMINDERS_APP_PASSWORD" => nil,
            "REMINDERS_DEFAULT_LIST" => nil,
          )
          replace_client!
        end

        def configure_tools
          define_list_tools
          define_reminder_tools
          define_write_tools
        end

        def replace_client!
          @client = Client.new
        end

        def credential_env_keys = %w[REMINDERS_APPLE_ID REMINDERS_APP_PASSWORD REMINDERS_DEFAULT_LIST]

        private

        def define_list_tools
          define_tool(
            name: "reminders_lists",
            description: "List iCloud reminder lists visible over CalDAV, including id, name, color, account, and whether it is the default.",
          ) { api_response(@client.lists) }

          define_tool(
            name: "reminders_list",
            description: "Fetch one Reminders list by id or name. Omit both to return the default list.",
            properties: list_target_properties,
          ) { |**args| api_response(@client.list(compact_payload(args))) }

          define_tool(
            name: "reminders_default_list",
            description: "Return the default Reminders list.",
          ) { api_response(@client.default_list) }

          define_tool(
            name: "reminders_search_lists",
            description: "Find lists whose name or account contains the query.",
            properties: { query: string_prop("Case-insensitive text matched against the list name and account.") },
          ) { |query: nil| api_response(@client.search_lists(query)) }
        end

        def define_reminder_tools
          define_tool(
            name: "reminders_get_reminders",
            description: "List reminders. Filter by list, due or completion range, completed state, and priority. Dates are ISO 8601 and inclusive.",
            properties: reminder_filter_properties,
          ) { |**args| api_response(@client.reminders(reminder_query(args))) }

          define_tool(
            name: "reminders_get",
            description: "Fetch one reminder by id.",
            properties: { id: string_prop("Reminder id.") },
            required: %w[id],
          ) { |id:| api_response(@client.reminder(id)) }

          define_tool(
            name: "reminders_next",
            description: "Return the next incomplete reminder whose due date is now or later. Omit the list to search every list.",
            properties: list_target_properties,
          ) { |**args| api_response({ "reminder" => @client.next_reminder(compact_payload(args)) }) }

          define_tool(
            name: "reminders_search",
            description: "Search reminder titles and notes. The same due, completion, list, and priority filters as reminders_get_reminders apply.",
            properties: reminder_filter_properties,
            required: %w[query],
          ) { |**args| api_response(@client.reminders(reminder_query(args))) }
        end

        def define_write_tools
          define_tool(
            name: "reminders_create",
            description: "Create a reminder on iCloud. Uses the default list, or REMINDERS_DEFAULT_LIST when that is set, unless list_id or list_name is passed. Priority names write Apple values: high=1, medium=5, low=9, none=0.",
            properties: reminder_write_properties,
            required: %w[title],
            write: true,
          ) { |**args| api_response(@client.create_reminder(reminder_write(args))) }

          define_tool(
            name: "reminders_update",
            description: "Update a reminder's title, notes, URL, due date, priority, or completion. Pass an empty due_date or url to clear it. CalDAV cannot move a reminder to another list.",
            properties: reminder_write_properties.merge(id: string_prop("Reminder id.")),
            required: %w[id],
            write: true,
          ) { |**args| api_response(@client.update_reminder(reminder_write(args))) }

          define_tool(
            name: "reminders_delete",
            description: "Delete a reminder by id.",
            properties: { id: string_prop("Reminder id.") },
            required: %w[id],
            write: true,
          ) { |id:| api_response(@client.delete_reminder(id)) }
        end

        def list_target_properties
          {
            list_id: string_prop("Reminders list id."),
            list_name: string_prop("Reminders list name. Case-insensitive exact match."),
            calendar_id: string_prop("Alias of list_id."),
            calendar_name: string_prop("Alias of list_name."),
          }
        end

        def reminder_filter_properties
          list_target_properties.merge(
            due_after: string_prop("ISO 8601 inclusive lower bound. Incomplete reminders use the due date. Completed reminders use the completion date."),
            due_before: string_prop("ISO 8601 inclusive upper bound. Same date field as due_after."),
            is_completed: boolean_prop("true returns completed reminders, false returns incomplete ones. Omit to include both."),
            priority: string_prop("none, low, medium, high, or an integer 0-9. none is 0, high is 1-4, medium is 5, low is 6-9."),
            query: string_prop("Case-insensitive text matched against the title and notes."),
            limit: integer_prop("Maximum reminders to return. Default 200. 0 returns every match."),
          )
        end

        def reminder_write_properties
          list_target_properties.merge(
            title: string_prop("Reminder title."),
            notes: string_prop("Notes stored in the VTODO description."),
            url: string_prop("URL stored on the VTODO. An empty string clears it on update."),
            due_date: string_prop("ISO 8601 due date. A date without a time is all-day. An empty string clears it on update."),
            priority: string_prop("none, low, medium, high, or an integer 0-9. Names write 0, 9, 5, and 1."),
            is_completed: boolean_prop("Mark the reminder complete or incomplete."),
          )
        end

        def reminder_query(args)
          payload = compact_payload(args.slice(:list_id, :list_name, :calendar_id, :calendar_name, :due_after, :due_before, :priority, :query))
          payload[:is_completed] = boolean_value(args[:is_completed]) unless args[:is_completed].nil?
          payload[:limit] = integer_value(args[:limit], "limit") unless args[:limit].nil? || args[:limit] == ""
          payload
        end

        def reminder_write(args)
          payload = compact_payload(args.slice(:id, :title, :list_id, :list_name, :calendar_id, :calendar_name, :priority))
          payload[:notes] = args[:notes] if args.key?(:notes) && !args[:notes].nil?
          payload[:url] = args[:url] if args.key?(:url) && !args[:url].nil?
          payload[:due_date] = args[:due_date] if args.key?(:due_date) && !args[:due_date].nil?
          payload[:is_completed] = boolean_value(args[:is_completed]) unless args[:is_completed].nil?
          payload
        end

        def compact_payload(payload)
          payload.each_with_object({}) do |(key, value), out|
            next if value.nil?
            next if value.is_a?(String) && value.strip.empty?

            out[key] = value
          end
        end

        def boolean_value(value)
          ActiveModel::Type::Boolean.new.cast(value)
        end

        def integer_value(value, name)
          number = Integer(value, exception: false)
          raise ArgumentError, "#{name} must be an integer" if number.nil?

          number
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::Reminders::Server)
