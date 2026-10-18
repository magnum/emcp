# frozen_string_literal: true

require "date"
require "time"

module Emcp
  module Servers
    module Reminders
      module Ics
        module_function

        PRIORITY_NAMES = { "none" => 0, "high" => 1, "medium" => 5, "low" => 9 }.freeze
        UPDATE_PROPERTIES = {
          summary: %w[SUMMARY],
          description: %w[DESCRIPTION],
          url: %w[URL],
          due: %w[DUE],
          priority: %w[PRIORITY],
          completed: %w[STATUS COMPLETED PERCENT-COMPLETE],
        }.freeze

        def priority_value(input)
          return 0 if input.nil? || input == ""

          name = input.to_s.strip.downcase
          return PRIORITY_NAMES[name] if PRIORITY_NAMES.key?(name)

          number = Integer(name, exception: false)
          unless number&.between?(0, 9)
            raise Client::Error, "priority must be none, low, medium, high, or an integer 0-9"
          end

          number
        end

        def priority_name(value)
          number = value.to_i
          return "none" if number <= 0
          return "high" if number <= 4
          return "medium" if number == 5

          "low"
        end

        def priority_match?(actual, wanted)
          value = actual.to_i
          name = wanted.to_s.strip.downcase
          case name
          when "none" then value.zero?
          when "high" then value.between?(1, 4)
          when "medium" then value == 5
          when "low" then value.between?(6, 9)
          else value == Integer(name, exception: false)
          end
        end

        def parse(text)
          lines = unfold(text)
          depth = 0
          vtodo_depth = nil
          current = nil
          found = []
          lines.each do |line|
            if line.start_with?("BEGIN:")
              depth += 1
              if line == "BEGIN:VTODO" && vtodo_depth.nil?
                vtodo_depth = depth
                current = blank_component
              end
              next
            end
            if line.start_with?("END:")
              if vtodo_depth && depth == vtodo_depth && line == "END:VTODO"
                found << current
                current = nil
                vtodo_depth = nil
              end
              depth -= 1
              next
            end
            assign_property(current, line) if current && depth == vtodo_depth
          end
          found
        end

        def parse_one(text)
          parse(text).first || raise(Client::Error, "VTODO is missing")
        end

        def generate(todo)
          lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//EmCP//Apple Reminders//EN",
            "BEGIN:VTODO",
            "UID:#{todo.fetch(:uid)}",
          ]
          lines.concat(property_lines(todo))
          lines << "END:VTODO"
          lines << "END:VCALENDAR"
          fold_lines(lines)
        end

        def rewrite(text, updates)
          lines = unfold(text)
          names = %w[DTSTAMP LAST-MODIFIED]
          updates.each_key { |key| names.concat(UPDATE_PROPERTIES[key] || []) }
          depth = 0
          vtodo_depth = nil
          output = []
          lines.each do |line|
            if line.start_with?("BEGIN:")
              depth += 1
              vtodo_depth = depth if line == "BEGIN:VTODO" && vtodo_depth.nil?
              output << line
              next
            end
            if line.start_with?("END:")
              if vtodo_depth && depth == vtodo_depth && line == "END:VTODO"
                output.concat(property_lines(updates))
                vtodo_depth = nil
              end
              depth -= 1
              output << line
              next
            end
            next if vtodo_depth && depth == vtodo_depth && names.include?(property_name(line))

            output << line
          end
          fold_lines(output)
        end

        def reminder(component, id:, list:)
          {
            "id" => id,
            "uid" => component[:uid],
            "title" => component[:summary].to_s,
            "notes" => component[:description],
            "url" => component[:url],
            "completed" => completed?(component),
            "due_date" => iso(component[:due]),
            "completion_date" => iso(component[:completed_at]),
            "priority" => component[:priority].to_i,
            "priority_name" => priority_name(component[:priority]),
            "list_id" => list["id"],
            "list_name" => list["name"],
            "created_date" => iso(component[:created]),
            "modified_date" => iso(component[:modified]),
          }
        end

        def completed?(component)
          component[:status].to_s.upcase == "COMPLETED" || component[:completed_at].present? || component[:percent].to_i == 100
        end

        def blank_component
          {
            uid: nil,
            summary: "",
            description: nil,
            url: nil,
            due: nil,
            completed_at: nil,
            status: "NEEDS-ACTION",
            priority: 0,
            percent: nil,
            created: nil,
            modified: nil,
          }
        end

        def assign_property(component, line)
          raw_name, value = line.split(":", 2)
          return if value.nil?

          name, *param_parts = raw_name.split(";")
          params = param_parts.to_h { |part| part.split("=", 2).then { |key, val| [ key.to_s.upcase, val.to_s ] } }
          text = value.strip
          case name.upcase
          when "UID" then component[:uid] = unescape(text)
          when "SUMMARY" then component[:summary] = unescape(text)
          when "DESCRIPTION" then component[:description] = unescape(text)
          when "URL" then component[:url] = text
          when "DUE" then component[:due] = parse_ics_time(text, params)
          when "COMPLETED" then component[:completed_at] = parse_ics_time(text, params)
          when "CREATED" then component[:created] = parse_ics_time(text, params)
          when "LAST-MODIFIED" then component[:modified] = parse_ics_time(text, params)
          when "STATUS" then component[:status] = text.upcase
          when "PRIORITY" then component[:priority] = text.to_i
          when "PERCENT-COMPLETE" then component[:percent] = text.to_i
          end
        end

        def property_lines(todo)
          stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
          lines = [ "DTSTAMP:#{stamp}", "LAST-MODIFIED:#{stamp}" ]
          lines << "SUMMARY:#{escape(todo[:summary])}" if todo.key?(:summary) && todo[:summary].present?
          lines << "DESCRIPTION:#{escape(todo[:description])}" if todo.key?(:description) && todo[:description].present?
          lines << "URL:#{todo[:url].to_s.strip}" if todo.key?(:url) && todo[:url].present?
          if todo.key?(:due)
            due = due_line(todo[:due])
            lines << due if due
          end
          lines << "PRIORITY:#{priority_value(todo[:priority])}" if todo.key?(:priority)
          if todo.key?(:completed)
            if todo[:completed]
              lines << "STATUS:COMPLETED"
              lines << "PERCENT-COMPLETE:100"
              lines << "COMPLETED:#{stamp}"
            else
              lines << "STATUS:NEEDS-ACTION"
            end
          end
          lines
        end

        def due_line(value)
          return if value.nil? || value == ""

          if value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
            return "DUE;VALUE=DATE:#{Date.iso8601(value).strftime('%Y%m%d')}"
          end

          parsed = value.is_a?(Time) ? value : parse_user_time(value)
          return if parsed.nil?

          "DUE:#{parsed.utc.strftime('%Y%m%dT%H%M%SZ')}"
        end

        def parse_ics_time(value, params)
          return Date.strptime(value, "%Y%m%d") if params["VALUE"].to_s.upcase == "DATE"

          if (zone_name = params["TZID"]).present?
            zone = Time.find_zone(zone_name)
            if zone && value.match?(/\A\d{8}T\d{6}\z/)
              return zone.strptime(value, "%Y%m%dT%H%M%S")&.utc
            end
          end

          stamp = value.end_with?("Z") ? value.delete_suffix("Z") : value
          return unless stamp.match?(/\A\d{8}T\d{6}\z/)

          Time.find_zone("UTC").strptime(stamp, "%Y%m%dT%H%M%S").utc
        rescue ArgumentError
          nil
        end

        def parse_user_time(value)
          return if value.nil? || value == ""
          return value.utc if value.is_a?(Time)
          return value.to_time(:utc) if value.is_a?(Date)

          text = value.to_s
          return Date.iso8601(text).to_time(:utc) if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          Time.iso8601(text).utc
        rescue ArgumentError
          Time.zone.parse(text)&.utc
        end

        def iso(value)
          return if value.nil?
          return value.strftime("%Y-%m-%d") if value.is_a?(Date)

          value.utc.iso8601
        end

        def unfold(text)
          text.to_s.gsub(/\r\n/, "\n").gsub(/\r/, "\n").gsub(/\n[ \t]/, "").split("\n").map(&:strip).reject(&:empty?)
        end

        def fold_lines(lines)
          "#{lines.map { |line| fold(line) }.join("\r\n")}\r\n"
        end

        def fold(line)
          return line if line.bytesize <= 75

          chunks = []
          rest = line
          first = true
          while rest.bytesize > (first ? 75 : 74)
            limit = first ? 75 : 74
            slice = +""
            rest.each_char do |char|
              break if (slice.bytesize + char.bytesize) > limit

              slice << char
            end
            break if slice.empty?

            chunks << (first ? slice : " #{slice}")
            rest = rest.byteslice(slice.bytesize..)
            first = false
          end
          chunks << (first ? rest : " #{rest}") unless rest.empty?
          chunks.join("\r\n")
        end

        def property_name(line)
          line.split(";", 2).first.to_s.split(":", 2).first.to_s.upcase
        end

        def unescape(value)
          value.to_s.gsub(/\\([\\nN,;])/) do
            case Regexp.last_match(1)
            when "n", "N" then "\n"
            when "\\" then "\\"
            else Regexp.last_match(1)
            end
          end
        end

        def escape(value)
          value.to_s.gsub("\\", "\\\\").gsub("\n", "\\n").gsub(",", "\\,").gsub(";", "\\;")
        end
      end
    end
  end
end
