# frozen_string_literal: true

module Emcp
  module Servers
    module Tessie
      module StateSummary
        MILES_TO_KM = 1.609344
        WINDOW_KEYS = %w[fd_window fp_window rd_window rp_window].freeze

        module_function

        def summarize(state)
          payload = state.is_a?(Hash) ? state : {}
          charge = hash_at(payload, "charge_state")
          climate = hash_at(payload, "climate_state")
          vehicle = hash_at(payload, "vehicle_state")
          drive = hash_at(payload, "drive_state")
          destination = first_present(drive["active_route_destination"], payload["active_route_destination"])
          minutes = first_present(drive["active_route_minutes_to_arrival"], payload["active_route_minutes_to_arrival"])
          miles = first_present(drive["active_route_miles_to_arrival"], payload["active_route_miles_to_arrival"])

          {
            "vin" => payload["vin"],
            "name" => payload["display_name"],
            "state" => payload["state"],
            "battery_percent" => number_at(charge, payload, "battery_level"),
            "range_km" => miles_to_km(first_present(charge["battery_range"], payload["battery_range"])),
            "charging" => charging?(first_present(charge["charging_state"], payload["charging_state"])),
            "charge_limit_percent" => number_at(charge, payload, "charge_limit_soc"),
            "climate_on" => truthy?(first_present(climate["is_climate_on"], payload["is_climate_on"])),
            "inside_c" => number_at(climate, payload, "inside_temp"),
            "outside_c" => number_at(climate, payload, "outside_temp"),
            "locked" => truthy?(first_present(vehicle["locked"], payload["locked"])),
            "windows_open" => WINDOW_KEYS.any? { |key| open?(first_present(vehicle[key], payload[key])) },
            "frunk_open" => open?(first_present(vehicle["ft"], payload["ft"])),
            "trunk_open" => open?(first_present(vehicle["rt"], payload["rt"])),
            "sentry" => truthy?(first_present(vehicle["sentry_mode"], payload["sentry_mode"])),
            "latitude" => number_at(drive, payload, "latitude"),
            "longitude" => number_at(drive, payload, "longitude"),
            "navigation" => {
              "active" => destination.present?,
              "destination" => destination,
              "minutes_to_arrival" => minutes&.to_f,
              "km_to_arrival" => miles_to_km(miles),
            },
          }
        end

        def vehicles(payload)
          rows = payload.is_a?(Hash) ? payload["results"] : payload
          Array(rows).filter_map do |row|
            next unless row.is_a?(Hash)

            last = row["last_state"].is_a?(Hash) ? row["last_state"] : {}
            vin = row["vin"].to_s
            next if vin.empty?

            {
              "vin" => vin,
              "name" => last["display_name"] || row["display_name"],
              "state" => last["state"] || row["state"],
            }
          end
        end

        def battery(payload)
          row = payload.is_a?(Hash) ? payload : {}
          {
            "battery_percent" => row["battery_level"],
            "range_km" => miles_to_km(row["battery_range"]),
            "ideal_range_km" => miles_to_km(row["ideal_battery_range"]),
            "energy_remaining_kwh" => row["energy_remaining"],
            "charging_amps" => row["charger_actual_current"] || row["pack_current"],
            "module_temp_min_c" => row["module_temp_min"],
            "module_temp_max_c" => row["module_temp_max"],
          }
        end

        def drives(payload)
          compact_rows(payload) do |row|
            {
              "id" => row["id"],
              "started_at" => row["started_at"],
              "ended_at" => row["ended_at"],
              "from" => row["starting_location"],
              "to" => row["ending_location"],
              "starting_battery" => row["starting_battery"],
              "ending_battery" => row["ending_battery"],
              "distance_km" => row["odometer_distance"],
              "energy_kwh" => row["energy_used"],
            }
          end
        end

        def charges(payload)
          compact_rows(payload) do |row|
            {
              "id" => row["id"],
              "started_at" => row["started_at"],
              "ended_at" => row["ended_at"],
              "location" => row["location"] || row["address"],
              "energy_added_kwh" => row["energy_added"],
              "starting_battery" => row["start_battery"] || row["starting_battery"],
              "ending_battery" => row["end_battery"] || row["ending_battery"],
              "supercharger" => row["is_supercharger"],
            }
          end
        end

        def miles_to_km(miles)
          return if miles.nil? || miles == ""

          (miles.to_f * MILES_TO_KM).round(1)
        end

        def compact_rows(payload)
          rows = payload.is_a?(Hash) ? payload["results"] : payload
          Array(rows).filter_map { |row| yield(row) if row.is_a?(Hash) }
        end

        def hash_at(payload, key)
          payload[key].is_a?(Hash) ? payload[key] : {}
        end

        def number_at(nested, payload, key)
          value = first_present(nested[key], payload[key])
          return if value.nil?

          value.to_f
        end

        def first_present(*values)
          values.find { |value| !value.nil? && value != "" }
        end

        def charging?(state)
          %w[Charging Starting].include?(state.to_s)
        end

        def truthy?(value)
          value == true || value.to_s == "true" || value.to_i == 1
        end

        def open?(value)
          return false if value.nil? || value == false

          value == true || value.to_f.positive?
        end
      end
    end
  end
end
