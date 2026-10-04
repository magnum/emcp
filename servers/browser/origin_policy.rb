# frozen_string_literal: true

require "uri"

module Emcp
  module Servers
    module Browser
      # Chrome match patterns (https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns).
      # A blank list means every HTTPS URL.
      class OriginPolicy
        DEFAULT = "https://*/*"

        PAGE_TOOLS = %w[
          browser_list_tabs
          browser_get_url
          browser_get_dom
          browser_get_text
          browser_query
          browser_read_table
          browser_accessibility_snapshot
          browser_screenshot
          browser_eval_readonly
          browser_navigate
          browser_switch_tab
          browser_open_tab
          browser_close_tab
          browser_click
          browser_type
          browser_select
          browser_set_value
          browser_check
          browser_scroll
          browser_wait_for
          browser_download
          browser_get_file
        ].freeze

        URL_TOOLS = %w[browser_navigate browser_open_tab browser_download browser_get_file].freeze

        PATTERN = %r{\A
          (?<scheme>\*|https?|file)://
          (?<host>\*|\*\.[^/:*]+|[^/:*]+)
          (?::(?<port>\d+))?
          (?<path>/.*)
        \z}ix

        def initialize(raw)
          @patterns = self.class.parse(raw)
        end

        def origins = @patterns

        def empty? = @patterns.empty?

        def allows_url?(url)
          return false if @patterns.empty?

          uri = self.class.coerce(url)
          return false unless uri&.host

          @patterns.any? { |pattern| self.class.match?(pattern, uri) }
        end

        def filter_tabs(tabs)
          Array(tabs).select { |tab| allows_url?(tab["url"] || tab[:url]) }
        end

        def self.parse(raw)
          text = raw.to_s.strip
          text = DEFAULT if text.empty?
          text.split(/[\s,]+/).filter_map { |entry| normalize(entry) }.uniq
        end

        def self.normalize(entry)
          value = entry.to_s.strip
          return if value.empty?

          value = "*://#{value}/*" unless value.include?("://")
          scheme_end = value.index("://")
          rest = value[(scheme_end + 3)..]
          value = "#{value.chomp("/")}/*" unless rest&.include?("/")
          spec = parse_pattern(value)
          return unless spec

          port = spec[:port] ? ":#{spec[:port]}" : ""
          "#{spec[:scheme]}://#{spec[:host]}#{port}#{spec[:path]}"
        end

        def self.match?(pattern, uri)
          spec = pattern.is_a?(Hash) ? pattern : parse_pattern(pattern)
          return false unless spec

          scheme = uri.scheme.to_s.downcase
          return false unless scheme_match?(spec[:scheme], scheme)
          return false unless host_match?(spec[:host], uri.host.to_s.downcase)
          return false if spec[:port] && uri.port != spec[:port]

          path = uri.path.to_s
          path = "/" if path.empty?
          path += "?#{uri.query}" if uri.query.present?
          path_match?(spec[:path], path)
        end

        def self.parse_pattern(value)
          match = PATTERN.match(value.to_s.strip)
          return unless match

          {
            scheme: match[:scheme].downcase,
            host: match[:host].downcase,
            port: (match[:port].to_i if match[:port]),
            path: match[:path],
          }
        end

        def self.coerce(url)
          value = url.to_s.strip
          return if value.empty?

          URI.parse(value.include?("://") ? value : "https://#{value}")
        rescue URI::InvalidURIError
          nil
        end

        def self.scheme_match?(pattern_scheme, scheme)
          return %w[http https].include?(scheme) if pattern_scheme == "*"

          scheme == pattern_scheme
        end

        def self.host_match?(pattern_host, host)
          return false if host.empty?
          return true if pattern_host == "*"

          if pattern_host.start_with?("*.")
            base = pattern_host.delete_prefix("*.")
            host.casecmp?(base) || host.end_with?(".#{base}")
          else
            host.casecmp?(pattern_host)
          end
        end

        def self.path_match?(pattern_path, path)
          body = Regexp.escape(pattern_path).gsub('\*', ".*")
          Regexp.new("\\A#{body}\\z", Regexp::IGNORECASE).match?(path)
        end
      end
    end
  end
end
