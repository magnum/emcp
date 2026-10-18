# frozen_string_literal: true

require "base64"
require "net/http"
require "nokogiri"
require "securerandom"
require "uri"

require_relative "reminders_ics"

module Emcp
  module Servers
    module Reminders
      class Client
        class Error < StandardError; end

        class Propfind < Net::HTTPRequest
          METHOD = "PROPFIND"
          REQUEST_HAS_BODY = true
          RESPONSE_HAS_BODY = true
        end

        class Report < Net::HTTPRequest
          METHOD = "REPORT"
          REQUEST_HAS_BODY = true
          RESPONSE_HAS_BODY = true
        end

        DEFAULT_URL = "https://caldav.icloud.com/"
        EMPTY_LIST_WARNING = "iCloud CalDAV returned no reminder lists. Apple does not expose lists that were upgraded to the current Reminders format on this API."
        LIST_CACHE_TTL = 30

        PRINCIPAL_XML = <<~XML.freeze
          <?xml version="1.0" encoding="UTF-8"?>
          <d:propfind xmlns:d="DAV:">
            <d:prop><d:current-user-principal/></d:prop>
          </d:propfind>
        XML
        HOME_XML = <<~XML.freeze
          <?xml version="1.0" encoding="UTF-8"?>
          <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
            <d:prop><c:calendar-home-set/></d:prop>
          </d:propfind>
        XML
        LISTS_XML = <<~XML.freeze
          <?xml version="1.0" encoding="UTF-8"?>
          <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/">
            <d:prop>
              <d:displayname/>
              <d:resourcetype/>
              <c:supported-calendar-component-set/>
              <a:calendar-color/>
            </d:prop>
          </d:propfind>
        XML
        REPORT_XML = <<~XML.freeze
          <?xml version="1.0" encoding="UTF-8"?>
          <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
            <d:prop>
              <d:getetag/>
              <c:calendar-data/>
            </d:prop>
            <c:filter>
              <c:comp-filter name="VCALENDAR">
                <c:comp-filter name="VTODO"/>
              </c:comp-filter>
            </c:filter>
          </c:calendar-query>
        XML

        def initialize(transport: nil, apple_id: nil, app_password: nil, base_url: nil, timeout: nil, clock: nil)
          @transport = transport
          @apple_id = apple_id
          @app_password = app_password
          @base_url = base_url
          @timeout = timeout
          @clock = clock || -> { Time.now.utc }
          @mutex = Mutex.new
        end

        def status
          rows = lists
          selected = rows.find { |row| row["default"] }
          body = { "lists" => rows.size, "default_list" => selected&.dig("name") }
          body["warning"] = EMPTY_LIST_WARNING if rows.empty?
          body
        end

        def lists
          @mutex.synchronize do
            if @lists && @lists_at && Time.now - @lists_at < LIST_CACHE_TTL
              return @lists
            end

            @lists = fetch_lists
            @lists_at = Time.now
            @lists
          end
        end

        def list(payload)
          find_list(payload)
        end

        def default_list
          lists.find { |row| row["default"] } || raise(Error, "No reminder list is available")
        end

        def search_lists(query)
          needle = query.to_s.strip.downcase
          lists.select do |row|
            needle.empty? || row["name"].to_s.downcase.include?(needle) || row["account"].to_s.downcase.include?(needle)
          end
        end

        def reminders(payload = {})
          data = payload.to_h.symbolize_keys
          rows = scoped_lists(data).flat_map { |row| todos(row) }
          filtered = rows.select { |row| matches?(row, data) }
          filtered.sort_by! { |row| row["due_date"] || "9999" }
          page(filtered, data[:limit])
        end

        def reminder(id)
          href = resolve_reminder_href(id)
          component = Ics.parse_one(get_ics(href))
          Ics.reminder(component, id: href, list: list_for(href))
        end

        def next_reminder(payload = {})
          rows = reminders(payload.to_h.symbolize_keys.merge(is_completed: false, limit: 0))["reminders"]
          rows.filter_map { |row| [ due_for_next(row), row ] }
            .select { |due, _row| due && due >= @clock.call }
            .min_by { |due, _row| due }
            &.last
        end

        def create_reminder(payload)
          data = with_default_list(payload.to_h.symbolize_keys)
          raise Error, "title is required" if data[:title].blank?

          list = find_list(data)
          uid = SecureRandom.uuid
          ics = Ics.generate(
            uid: uid,
            summary: data[:title],
            description: data[:notes],
            url: data[:url],
            due: data[:due_date],
            priority: data.key?(:priority) ? Ics.priority_value(data[:priority]) : 0,
            completed: data[:is_completed] == true,
          )
          href = child_url(list["id"], "#{uid}.ics")
          put_ics(href, ics)
          Ics.reminder(Ics.parse_one(ics), id: href, list: list)
        end

        def update_reminder(payload)
          data = payload.to_h.symbolize_keys
          href = resolve_reminder_href(data[:id])
          updates = {}
          updates[:summary] = data[:title] if data.key?(:title)
          updates[:description] = data[:notes] if data.key?(:notes)
          updates[:url] = data[:url] if data.key?(:url)
          updates[:due] = data[:due_date] if data.key?(:due_date)
          updates[:priority] = Ics.priority_value(data[:priority]) if data.key?(:priority)
          updates[:completed] = data[:is_completed] if data.key?(:is_completed)
          rewritten = Ics.rewrite(get_ics(href), updates)
          put_ics(href, rewritten)
          Ics.reminder(Ics.parse_one(rewritten), id: href, list: list_for(href))
        end

        def delete_reminder(id)
          href = resolve_reminder_href(id)
          response = request("DELETE", href)
          raise Error, "Reminder not found: #{id}" if response[:status].to_i == 404

          ensure_ok!(response, "DELETE")
          { "deleted" => true, "id" => href }
        end

        private

        def with_default_list(payload)
          return payload if payload[:list_id].present? || payload[:list_name].present? || payload[:calendar_id].present? || payload[:calendar_name].present?

          name = Emcp.sanitize_env_value(ENV["REMINDERS_DEFAULT_LIST"])
          return payload if name.empty?

          payload.merge(list_name: name)
        end

        def fetch_lists
          home = calendar_home
          rows = calendar_collections(home).map { |row| serialize_list(row) }
          mark_default!(rows)
          rows
        end

        def calendar_home
          principal_xml = propfind(root_url, PRINCIPAL_XML, depth: 0)
          principal_href = text_at(principal_xml, "current-user-principal href")
          raise Error, "iCloud CalDAV discovery failed: missing current-user-principal" if principal_href.blank?

          principal = absolute_url(root_url, principal_href)
          home_xml = propfind(principal, HOME_XML, depth: 0)
          home_href = text_at(home_xml, "calendar-home-set href")
          raise Error, "iCloud CalDAV discovery failed: missing calendar-home-set" if home_href.blank?

          absolute_url(principal, home_href)
        end

        def calendar_collections(home)
          xml = propfind(home, LISTS_XML, depth: 1)
          document(xml).css("response").filter_map do |response|
            href = direct_text(response, "href")
            next if href.blank?

            absolute = absolute_url(home, href)
            next if absolute.delete_suffix("/") == home.delete_suffix("/")
            next if absolute.match?(%r{/(inbox|outbox|notification)(/|\z)}i)
            next unless response.at_css("resourcetype calendar")

            components = response.css("comp").map { |node| node["name"].to_s.upcase }
            next if components.any? && !components.include?("VTODO")

            {
              "href" => absolute,
              "name" => first_text(response, "displayname").presence || "Reminders",
              "color" => first_text(response, "calendar-color").presence,
            }
          end
        end

        def serialize_list(row)
          {
            "id" => row["href"],
            "name" => row["name"],
            "color" => row["color"],
            "account" => apple_id,
            "default" => false,
          }
        end

        def mark_default!(rows)
          name = Emcp.sanitize_env_value(ENV["REMINDERS_DEFAULT_LIST"])
          selected = if name.present?
            rows.find { |row| row["name"].casecmp?(name) }
          else
            rows.find { |row| row["name"].casecmp?("Reminders") } || rows.first
          end
          selected["default"] = true if selected
        end

        def scoped_lists(payload)
          if payload[:list_id].present? || payload[:list_name].present? || payload[:calendar_id].present? || payload[:calendar_name].present?
            [ find_list(payload) ]
          else
            lists
          end
        end

        def find_list(payload)
          data = payload.to_h.symbolize_keys
          id = data[:list_id].presence || data[:calendar_id].presence
          name = data[:list_name].presence || data[:calendar_name].presence
          if id
            return lists.find { |row| row["id"] == id } || raise(Error, "List not found: #{id}")
          end
          if name
            return lists.find { |row| row["name"].casecmp?(name) } || raise(Error, "List not found: #{name}")
          end

          default_list
        end

        def todos(list)
          document(report(list["id"])).css("response").filter_map do |response|
            href = direct_text(response, "href")
            ics = response.at_css("calendar-data")&.text
            next if href.blank? || ics.blank?

            component = Ics.parse(ics).first
            next unless component

            Ics.reminder(component, id: absolute_url(list["id"], href), list: list)
          end
        end

        def matches?(row, payload)
          unless payload[:is_completed].nil?
            return false if row["completed"] != payload[:is_completed]
          end
          query = payload[:query].to_s.strip.downcase
          if query.present?
            haystack = "#{row["title"]}\n#{row["notes"]}".downcase
            return false unless haystack.include?(query)
          end
          return false if payload[:priority].present? && !Ics.priority_match?(row["priority"], payload[:priority])
          return true if payload[:due_after].blank? && payload[:due_before].blank?

          stamp = parse_bound(row["completed"] ? row["completion_date"] : row["due_date"], :start)
          return false if stamp.nil?
          return false if payload[:due_after].present? && stamp < parse_bound(payload[:due_after], :start)
          return false if payload[:due_before].present? && stamp > parse_bound(payload[:due_before], :end)

          true
        end

        def due_for_next(row)
          value = row["due_date"]
          return if value.blank?

          parsed = parse_bound(value, :start)
          return parsed&.end_of_day&.utc if value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          parsed
        end

        def parse_bound(value, edge)
          parsed = Ics.parse_user_time(value)
          return if parsed.nil?
          return parsed unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          edge == :end ? parsed.end_of_day.utc : parsed.beginning_of_day.utc
        end

        def page(rows, limit)
          cap = limit.nil? || limit == "" ? 200 : Integer(limit, exception: false)
          raise Error, "limit must be an integer" if cap.nil?

          sliced = cap.positive? ? rows.first(cap) : rows
          { "reminders" => sliced, "total" => rows.size, "truncated" => sliced.size < rows.size }
        end

        def resolve_reminder_href(id)
          text = id.to_s
          raise Error, "id is required" if text.blank?
          return absolute_url(root_url, text) if text.start_with?("http://", "https://", "/")

          found = reminders(limit: 0)["reminders"].find { |row| row["uid"] == text || row["id"] == text }
          raise Error, "Reminder not found: #{text}" unless found

          found["id"]
        end

        def list_for(href)
          lists.find { |row| href.start_with?(row["id"]) } || { "id" => nil, "name" => nil }
        end

        def propfind(url, xml, depth:)
          response = request("PROPFIND", url, headers: xml_headers("Depth" => depth.to_s), body: xml)
          ensure_ok!(response, "PROPFIND")
          response[:body]
        end

        def report(url)
          response = request("REPORT", url, headers: xml_headers("Depth" => "1"), body: REPORT_XML)
          ensure_ok!(response, "REPORT")
          response[:body]
        end

        def get_ics(url)
          response = request("GET", url, headers: { "Accept" => "text/calendar" })
          raise Error, "Reminder not found: #{url}" if response[:status].to_i == 404

          ensure_ok!(response, "GET")
          response[:body]
        end

        def put_ics(url, body)
          response = request("PUT", url, headers: { "Content-Type" => "text/calendar; charset=utf-8" }, body: body)
          ensure_ok!(response, "PUT")
        end

        def xml_headers(extra)
          { "Content-Type" => "application/xml; charset=utf-8" }.merge(extra)
        end

        def request(method, url, headers: {}, body: nil, redirects: 0)
          raise Error, "iCloud CalDAV redirect limit reached" if redirects > 5

          uri = URI(url)
          raise Error, "iCloud CalDAV only talks to icloud.com" unless icloud_host?(uri)

          headers = { "User-Agent" => "EmCP", "Authorization" => basic_auth }.merge(headers)
          response = @transport ? transport_response(method, url, headers, body) : http_response(method, uri, headers, body)
          status = response[:status].to_i
          if status.between?(300, 399)
            location = response[:headers].to_h.transform_keys { |key| key.to_s.downcase }["location"]
            raise Error, "iCloud CalDAV redirect had no Location" if location.blank?

            return request(method, absolute_url(url, location), headers: headers.except("Authorization"), body: body, redirects: redirects + 1)
          end
          response
        rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
          raise Error, "iCloud CalDAV request failed: #{e.message}"
        end

        def transport_response(method, url, headers, body)
          raw = @transport.call(method, url, headers, body)
          {
            status: raw[:status] || raw["status"],
            headers: raw[:headers] || raw["headers"] || {},
            body: (raw[:body] || raw["body"]).to_s,
          }
        end

        def http_response(method, uri, headers, body)
          http_request = request_class(method).new(uri.request_uri)
          headers.each { |key, value| http_request[key] = value }
          http_request.body = body if body
          seconds = timeout_seconds
          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: seconds,
            read_timeout: seconds,
            write_timeout: seconds,
          ) { |http| http.request(http_request) }
          {
            status: response.code.to_i,
            headers: response.each_header.to_h,
            body: response.body.to_s,
          }
        end

        def request_class(method)
          case method.to_s.upcase
          when "GET" then Net::HTTP::Get
          when "PUT" then Net::HTTP::Put
          when "DELETE" then Net::HTTP::Delete
          when "PROPFIND" then Propfind
          when "REPORT" then Report
          else raise Error, "Unsupported CalDAV method: #{method}"
          end
        end

        def ensure_ok!(response, action)
          status = response[:status].to_i
          return response if status.between?(200, 299)
          if status == 401 || status == 403
            raise Error, "iCloud rejected the Apple ID or app-specific password (HTTP #{status})"
          end

          detail = response[:body].to_s.gsub(app_password, "[redacted]")[0, 180]
          suffix = detail.present? ? ": #{detail}" : ""
          raise Error, "iCloud CalDAV #{action} failed (HTTP #{status})#{suffix}"
        end

        def document(xml)
          doc = Nokogiri::XML(xml.to_s) { |config| config.recover.nonet }
          doc.remove_namespaces!
          doc
        end

        def text_at(xml, selector)
          document(xml).at_css(selector)&.text.to_s.strip
        end

        def direct_text(node, name)
          node.element_children.find { |child| child.name == name }&.text.to_s.strip
        end

        def first_text(node, name)
          node.css(name).map { |child| child.text.to_s.strip }.find(&:present?).to_s
        end

        def absolute_url(base, href)
          text = href.to_s.strip
          raise Error, "CalDAV href is missing" if text.empty?

          uri = if text.start_with?("https://", "http://")
            URI(text)
          elsif text.start_with?("/")
            origin = URI(base)
            origin.path = text
            origin.query = nil
            origin.fragment = nil
            origin
          else
            joined = base.end_with?("/") ? base : "#{base}/"
            URI.join(joined, text)
          end
          raise Error, "CalDAV href is not on icloud.com" unless icloud_host?(uri)

          strip_default_port(uri).to_s
        end

        def child_url(collection, name)
          base = collection.end_with?("/") ? collection : "#{collection}/"
          URI.join(base, name).to_s
        end

        def strip_default_port(uri)
          uri.port = nil if (uri.scheme == "https" && uri.port == 443) || (uri.scheme == "http" && uri.port == 80)
          uri
        end

        def icloud_host?(uri)
          host = uri.host.to_s.downcase
          host == "icloud.com" || host.end_with?(".icloud.com")
        end

        def root_url
          raw = @base_url.presence || Emcp.sanitize_env_value(ENV["REMINDERS_CALDAV_URL"])
          raw = DEFAULT_URL if raw.blank?
          uri = URI(raw)
          unless uri.scheme == "https" && icloud_host?(uri)
            raise Error, "REMINDERS_CALDAV_URL must be an https URL on icloud.com"
          end

          uri.path = "/" if uri.path.blank?
          strip_default_port(uri).to_s
        end

        def basic_auth
          id, password = credentials!
          "Basic #{Base64.strict_encode64("#{id}:#{password}")}"
        end

        def credentials!
          id = apple_id
          password = app_password
          raise Error, "REMINDERS_APPLE_ID is not configured" if id.empty?
          raise Error, "REMINDERS_APP_PASSWORD is not configured" if password.empty?
          if id.match?(/[\r\n]/) || password.match?(/[\r\n]/)
            raise Error, "Apple ID or app-specific password contains invalid characters"
          end

          [ id, password ]
        end

        def apple_id
          Emcp.sanitize_env_value(@apple_id || ENV["REMINDERS_APPLE_ID"])
        end

        def app_password
          Emcp.sanitize_env_value(@app_password || ENV["REMINDERS_APP_PASSWORD"])
        end

        def timeout_seconds
          value = @timeout || Integer(ENV.fetch("REMINDERS_TIMEOUT", "60"), exception: false)
          value.to_i.positive? ? value.to_i : 60
        end
      end
    end
  end
end
