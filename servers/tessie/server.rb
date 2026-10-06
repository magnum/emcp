# frozen_string_literal: true

require_relative "tessie_client"
require_relative "state_summary"

module Emcp
  module Servers
    module Tessie
      class Server < ::McpServer
        server_id "tessie"
        display_name "Tessie"
        description "Read and command Tesla vehicles through the Tessie API."
        version "0.1.0"

        COMMANDS = {
          "tessie_lock" => [ "lock", "Lock the vehicle." ],
          "tessie_unlock" => [ "unlock", "Unlock the vehicle." ],
          "tessie_climate_start" => [ "start_climate", "Start the climate system." ],
          "tessie_climate_stop" => [ "stop_climate", "Stop the climate system." ],
          "tessie_charge_start" => [ "start_charging", "Start charging." ],
          "tessie_charge_stop" => [ "stop_charging", "Stop charging." ],
          "tessie_open_charge_port" => [ "open_charge_port", "Open or unlock the charge port." ],
          "tessie_close_charge_port" => [ "close_charge_port", "Close the charge port." ],
          "tessie_honk" => [ "honk", "Honk the horn." ],
          "tessie_flash_lights" => [ "flash_lights", "Flash the lights." ],
          "tessie_vent_windows" => [ "vent_windows", "Vent all windows." ],
          "tessie_close_windows" => [ "close_windows", "Close all windows." ],
          "tessie_open_frunk" => [ "activate_front_trunk", "Open the front trunk." ],
          "tessie_open_trunk" => [ "activate_rear_trunk", "Open the rear trunk, or close a powered trunk." ],
          "tessie_sentry_on" => [ "enable_sentry", "Turn Sentry Mode on." ],
          "tessie_sentry_off" => [ "disable_sentry", "Turn Sentry Mode off." ],
        }.freeze

        def instructions
          "Use Tessie tools to read a Tesla and, when this instance allows writes, send commands. " \
            "Reads use Tessie's cached vehicle state and do not wake the car. " \
            "Commands wake the car when it is asleep, then call the Tessie command with wait_for_completion. " \
            "Pass vin or omit it to use TESSIE_DEFAULT_VIN, or the first vehicle on the account. " \
            "Distances in summaries are kilometers. Temperatures are Celsius. Tire pressure is bar. " \
            "Write tools stay disabled unless allow_write is on for this instance."
        end

        def auth_help_content
          {
            title: "Connect Tessie",
            description: "EmCP calls https://api.tessie.com with a token from the Tessie dashboard.",
            steps: [
              "Open https://dash.tessie.com/settings/api and generate an access token.",
              "Paste it below. EmCP sends it as Authorization: Bearer.",
              "Optional: set a default VIN. Otherwise tools use the first vehicle from GET /vehicles.",
              "Leave Allow write off until you want lock, climate, charge, and the other commands.",
            ],
            commands: [
              { label: "List vehicles", value: 'curl -s -H "Authorization: Bearer $TESSIE_API_TOKEN" https://api.tessie.com/vehicles' },
            ],
            note: "Reads do not wake the vehicle. Commands do, and they require allow write on this instance.",
          }
        end

        def auth_fields
          [
            {
              name: "tessie_api_token",
              label: "API token",
              type: "password",
              required: true,
              help: "From dash.tessie.com/settings/api. Leave blank to keep a saved token.",
              env: "TESSIE_API_TOKEN",
            },
            {
              name: "tessie_default_vin",
              label: "Default VIN",
              type: "text",
              required: false,
              help: "Optional. Tools use this VIN when one is not passed.",
              env: "TESSIE_DEFAULT_VIN",
            },
            {
              name: "tessie_allow_write",
              label: "Allow write",
              type: "checkbox",
              help: "Lock, climate, charge, honk, trunks, sentry, and destination sharing. Saved on this instance.",
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
          if Emcp.sanitize_env_value(ENV["TESSIE_API_TOKEN"]).empty?
            return { authenticated: false, error: "TESSIE_API_TOKEN is not configured" }
          end

          rows = StateSummary.vehicles(@client.vehicles)
          {
            authenticated: true,
            vehicles: rows.size,
            default_vin: Emcp.sanitize_env_value(ENV["TESSIE_DEFAULT_VIN"]).presence,
          }
        rescue StandardError => e
          { authenticated: false, error: e.message }
        end

        def apply_credentials(params)
          load_credentials!
          token = Emcp.sanitize_env_value(params["tessie_api_token"])
          updates = {}
          updates["TESSIE_API_TOKEN"] = token if token.present?
          if params.key?("tessie_default_vin")
            updates["TESSIE_DEFAULT_VIN"] = Emcp.sanitize_env_value(params["tessie_default_vin"])
          end
          effective = updates["TESSIE_API_TOKEN"].presence || Emcp.sanitize_env_value(ENV["TESSIE_API_TOKEN"])
          raise "TESSIE_API_TOKEN is required" if effective.empty?

          apply_credentials_probe!(updates, rejection_message: "Tessie token was rejected")
          if params.key?("tessie_allow_write")
            update!(allow_write: ActiveModel::Type::Boolean.new.cast(params["tessie_allow_write"]))
          end
          true
        ensure
          token = nil
        end

        def clear_credentials!
          persist_credentials!("TESSIE_API_TOKEN" => nil, "TESSIE_DEFAULT_VIN" => nil)
          replace_client!
        end

        def configure_tools
          define_read_tools
          define_command_tools
        end

        def replace_client!
          @client = Client.new
        end

        def credential_env_keys = %w[TESSIE_API_TOKEN TESSIE_DEFAULT_VIN]

        private

        def define_read_tools
          define_tool(
            name: "tessie_list_vehicles",
            description: "List vehicles on this Tessie account (VIN, name, online/asleep). Uses the cached state and does not wake the car.",
          ) { api_response(StateSummary.vehicles(@client.vehicles)) }

          define_tool(
            name: "tessie_get_state",
            description: "Compact vehicle summary: battery, range in km, charging, climate, lock, openings, sentry, location, and navigation. raw=true returns the full Tessie JSON. Does not wake the car.",
            properties: {
              vin: string_prop("Vehicle VIN. Optional when TESSIE_DEFAULT_VIN is set."),
              raw: boolean_prop("Return the full Tessie state JSON."),
            },
          ) do |vin: nil, raw: false|
            resolved = resolve_vin(vin)
            payload = @client.state(resolved)
            api_response(raw == true || raw.to_s == "true" ? payload : StateSummary.summarize(payload))
          end

          define_tool(
            name: "tessie_get_location",
            description: "Address, coordinates, and saved location. Does not wake the car.",
            properties: { vin: string_prop("Vehicle VIN. Optional when a default is set.") },
          ) { |vin: nil| api_response(@client.location(resolve_vin(vin))) }

          define_tool(
            name: "tessie_get_battery",
            description: "Battery percent, range in km, and pack temperatures. Does not wake the car.",
            properties: { vin: string_prop("Vehicle VIN. Optional when a default is set.") },
          ) { |vin: nil| api_response(StateSummary.battery(@client.battery(resolve_vin(vin)))) }

          define_tool(
            name: "tessie_get_drives",
            description: "Recent drives in kilometers and Celsius. from and to are ISO 8601 or a Unix timestamp. Does not wake the car.",
            properties: history_properties,
          ) do |vin: nil, from: nil, to: nil, limit: nil|
            api_response(StateSummary.drives(@client.drives(resolve_vin(vin), history_query(from, to, limit))))
          end

          define_tool(
            name: "tessie_get_charges",
            description: "Recent charges. from and to are ISO 8601 or a Unix timestamp. Does not wake the car.",
            properties: history_properties,
          ) do |vin: nil, from: nil, to: nil, limit: nil|
            api_response(StateSummary.charges(@client.charges(resolve_vin(vin), history_query(from, to, limit))))
          end

          define_tool(
            name: "tessie_get_tire_pressure",
            description: "Tire pressure in bar. Does not wake the car.",
            properties: { vin: string_prop("Vehicle VIN. Optional when a default is set.") },
          ) { |vin: nil| api_response(@client.tire_pressure(resolve_vin(vin))) }
        end

        def define_command_tools
          vin_prop = { vin: string_prop("Vehicle VIN. Optional when a default is set.") }
          COMMANDS.each do |tool_name, (command, description)|
            define_tool(
              name: tool_name,
              description: "#{description} Wakes the vehicle when it is asleep. Requires allow write.",
              properties: vin_prop,
              write: true,
            ) do |vin: nil|
              api_response(run_command(command, vin))
            end
          end

          define_tool(
            name: "tessie_set_temperature",
            description: "Set the cabin temperature in Celsius (15–28). Wakes the vehicle when it is asleep. Requires allow write.",
            properties: vin_prop.merge(celsius: { type: "number", description: "Cabin temperature in Celsius, from 15 to 28." }),
            required: [ "celsius" ],
            write: true,
          ) do |celsius:, vin: nil|
            degrees = celsius.to_f
            raise "Temperature must be between 15 and 28 Celsius" unless degrees.between?(15, 28)

            api_response(run_command("set_temperatures", vin, "temperature" => degrees))
          end

          define_tool(
            name: "tessie_set_charge_limit",
            description: "Set the charge limit percent (50–100). Wakes the vehicle when it is asleep. Requires allow write.",
            properties: vin_prop.merge(percent: { type: "integer", description: "Charge limit from 50 to 100." }),
            required: [ "percent" ],
            write: true,
          ) do |percent:, vin: nil|
            limit = percent.to_i
            raise "Charge limit must be between 50 and 100" unless limit.between?(50, 100)

            api_response(run_command("set_charge_limit", vin, "percent" => limit))
          end

          define_tool(
            name: "tessie_share_destination",
            description: "Send an address to the vehicle navigator. Wakes the vehicle when it is asleep. Requires allow write.",
            properties: vin_prop.merge(
              address: string_prop("Street address, coordinates, or a video URL."),
              locale: string_prop("Address locale, default it-IT."),
            ),
            required: [ "address" ],
            write: true,
          ) do |address:, vin: nil, locale: nil|
            value = address.to_s.strip
            raise "Address is required" if value.empty?

            api_response(run_command("share", vin, "value" => value, "locale" => (locale.presence || "it-IT")))
          end

          define_tool(
            name: "tessie_wake",
            description: "Wake the vehicle. Requires allow write. Returns when the car is awake, or after Tessie's timeout.",
            properties: vin_prop,
            write: true,
          ) do |vin: nil|
            resolved = resolve_vin(vin)
            result = @client.wake(resolved)
            api_response(command_payload("wake", resolved, result, result["result"] ? "Vehicle is awake." : "Vehicle stayed asleep."))
          end
        end

        def run_command(command, vin, query = {})
          resolved = resolve_vin(vin)
          ensure_awake!(resolved)
          result = @client.command(resolved, command, query: query)
          ok = result.is_a?(Hash) && result["result"] == true
          command_payload(command, resolved, result, ok ? "#{command} completed." : "#{command} did not complete.")
        end

        def ensure_awake!(vin)
          current = @client.status(vin)
          return if current.is_a?(Hash) && current["status"] == "awake"

          woken = @client.wake(vin)
          return if woken.is_a?(Hash) && woken["result"] == true

          raise "The vehicle stayed asleep, so the command was not sent."
        end

        def command_payload(command, vin, result, message)
          {
            "ok" => result.is_a?(Hash) && result["result"] == true,
            "command" => command,
            "vin" => vin,
            "message" => message,
            "result" => result,
          }
        end

        def resolve_vin(vin)
          explicit = vin.to_s.strip
          return explicit if explicit.present?

          fallback = Emcp.sanitize_env_value(ENV["TESSIE_DEFAULT_VIN"])
          return fallback if fallback.present?

          first = StateSummary.vehicles(@client.vehicles).first
          raise "No vehicles on this Tessie account. Set TESSIE_DEFAULT_VIN or pass vin." if first.nil?

          first["vin"]
        end

        def history_properties
          {
            vin: string_prop("Vehicle VIN. Optional when a default is set."),
            from: string_prop("Start time, ISO 8601 or a Unix timestamp in seconds."),
            to: string_prop("End time, ISO 8601 or a Unix timestamp in seconds."),
            limit: integer_prop("Maximum number of rows, from 1 to 50. Default 10."),
          }
        end

        def history_query(from, to, limit)
          {
            "from" => epoch(from),
            "to" => epoch(to),
            "limit" => (limit.nil? || limit == "" ? 10 : limit.to_i.clamp(1, 50)),
          }.compact
        end

        def epoch(value)
          text = value.to_s.strip
          return if text.empty?
          return text.to_i if text.match?(/\A\d+\z/)

          Time.iso8601(text).to_i
        rescue ArgumentError
          raise "Time must be ISO 8601 or a Unix timestamp: #{text}"
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::Tessie::Server)
