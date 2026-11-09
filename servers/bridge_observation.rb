# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Emcp
  module Servers
    # The Go bridge listens on 127.0.0.1 inside the web container. The status
    # job runs on the Solid Queue worker, which cannot open that port and must
    # not start a second bridge. The web process writes a short snapshot; the
    # worker reads it.
    module BridgeObservation
      FRESH_FOR = 90

      def write_observed_status!(payload)
        body = payload.is_a?(Hash) ? payload.stringify_keys : {}
        body = body.except("qr", "qr_png_base64")
        body["checked_at"] = Time.current.iso8601
        FileUtils.mkdir_p(store_dir)
        File.write(observation_path, JSON.generate(body), perm: 0o600)
      end

      def read_observed_status
        return unless File.file?(observation_path)

        raw = JSON.parse(File.read(observation_path))
        return unless raw.is_a?(Hash)

        checked = Time.iso8601(raw["checked_at"].to_s)
        return if Time.current - checked > FRESH_FOR

        raw
      rescue ArgumentError, JSON::ParserError, SystemCallError
        nil
      end

      def observation_path
        File.join(store_dir, "bridge.status.json")
      end
    end
  end
end
