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
          destination = text_at(drive["active_route_destination"], payload["active_route_destination"])
          minutes = number_at(drive, payload, "active_route_minutes_to_arrival")
          miles = positive_number_at(drive, payload, "active_route_miles_to_arrival")

          {
            "vin" => text_at(payload["vin"]),
            "name" => text_at(payload["display_name"]),
            "state" => text_at(payload["state"]),
            "battery_percent" => number_at(charge, payload, "battery_level"),
            "range_km" => driving_range_km(charge, payload),
            "ideal_range_km" => ideal_range_km(charge, payload),
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
              "minutes_to_arrival" => minutes,
              "km_to_arrival" => miles_to_km(miles),
            }.compact,
          }.compact
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
            "battery_percent" => numeric(row["battery_level"]),
            "range_km" => driving_range_km(row, {}),
            "ideal_range_km" => ideal_range_km(row, {}),
            "energy_remaining_kwh" => numeric(row["energy_remaining"]),
            "charging_amps" => first_numeric(row["charger_actual_current"], row["pack_current"]),
            "module_temp_min_c" => numeric(row["module_temp_min"]),
            "module_temp_max_c" => numeric(row["module_temp_max"]),
          }.compact
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
          number = numeric(miles)
          return if number.nil?

          (number * MILES_TO_KM).round(1)
        end

        # Estimated range first. Ideal range on a cached asleep payload is often 0, nil, or false
        # while battery_range / est_battery_range still holds the usable distance.
        def driving_range_km(charge, payload)
          miles_to_km(first_positive(charge, payload, "battery_range", "est_battery_range", "rated_battery_range"))
        end

        def ideal_range_km(charge, payload)
          miles = first_positive(charge, payload, "ideal_battery_range")
          miles ||= first_positive(charge, payload, "rated_battery_range", "est_battery_range", "battery_range")
          miles_to_km(miles)
        end

        def compact_rows(payload)
          rows = payload.is_a?(Hash) ? payload["results"] : payload
          Array(rows).filter_map { |row| yield(row) if row.is_a?(Hash) }
        end

        def hash_at(payload, key)
          payload[key].is_a?(Hash) ? payload[key] : {}
        end

        def number_at(nested, payload, key)
          first_numeric(nested[key], payload[key])
        end

        def positive_number_at(nested, payload, key)
          first_positive(nested, payload, key)
        end

        def first_present(*values)
          values.find { |value| !value.nil? && value != "" }
        end

        def first_numeric(*values)
          values.each do |value|
            number = numeric(value)
            return number unless number.nil?
          end
          nil
        end

        def first_positive(nested, payload, *keys)
          keys.each do |key|
            number = first_numeric(nested[key], payload[key])
            return number if number&.positive?
          end
          nil
        end

        def numeric(value)
          return value.to_f if value.is_a?(Numeric)
          return if value.nil? || value == false || value == true

          text = value.to_s.strip
          return unless text.match?(/\A-?\d+(?:\.\d+)?\z/)

          text.to_f
        end

        def text_at(*values)
          values.each do |value|
            next if value.nil? || value == false || value == true

            text = value.to_s.strip
            return text unless text.empty?
          end
          nil
        end

        def charging?(state)
          return false if state.nil? || state == false || state == true

          %w[Charging Starting].include?(state.to_s)
        end

        def truthy?(value)
          return true if value == true
          return false if value.nil? || value == false
          return true if value.to_s == "true"

          numeric(value) == 1
        end

        def open?(value)
          return true if value == true
          return false if value.nil? || value == false

          number = numeric(value)
          !number.nil? && number.positive?
        end
      end
    end
  end
end
