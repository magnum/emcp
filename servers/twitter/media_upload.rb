# frozen_string_literal: true

require "base64"
require "ipaddr"
require "json"
require "net/http"
require "uri"

module Emcp
  module Servers
    module Twitter
      # X API v2 media upload (docs.x.com/x-api/media).
      # Simple images: POST /2/media/upload.
      # Video and GIFs over 5 MB: POST /2/media/upload/initialize, /{id}/append, /{id}/finalize,
      # then GET /2/media/upload?command=STATUS until processing_info.state is succeeded.
      # Alt text: POST /2/media/metadata.
      class MediaUpload
        IMAGE_LIMIT = 5 * 1024 * 1024
        GIF_LIMIT = 15 * 1024 * 1024
        VIDEO_LIMIT = 8 * 1024 * 1024 * 1024
        CHUNK_BYTES = 4 * 1024 * 1024
        STATUS_BUDGET = 120
        MAX_STATUS_POLLS = 40
        MAX_REDIRECTS = 3
        ALT_TEXT_LIMIT = 1000
        CATEGORIES = %w[tweet_image tweet_gif tweet_video].freeze

        MIME_TYPES = {
          "image/jpg" => "image/jpeg",
          "image/pjpeg" => "image/jpeg",
          "image/jpeg" => "image/jpeg",
          "image/png" => "image/png",
          "image/webp" => "image/webp",
          "image/gif" => "image/gif",
          "video/mp4" => "video/mp4",
          "video/quicktime" => "video/quicktime",
          "video/webm" => "video/webm",
        }.freeze

        CATEGORY_FOR_MIME = {
          "image/jpeg" => "tweet_image",
          "image/png" => "tweet_image",
          "image/webp" => "tweet_image",
          "image/gif" => "tweet_gif",
          "video/mp4" => "tweet_video",
          "video/quicktime" => "tweet_video",
          "video/webm" => "tweet_video",
        }.freeze

        EXTENSIONS = {
          ".jpg" => "image/jpeg",
          ".jpeg" => "image/jpeg",
          ".png" => "image/png",
          ".webp" => "image/webp",
          ".gif" => "image/gif",
          ".mp4" => "video/mp4",
          ".mov" => "video/quicktime",
          ".webm" => "video/webm",
        }.freeze

        def initialize(client, sleeper: ->(seconds) { sleep(seconds) }, timeout: nil)
          @client = client
          @sleeper = sleeper
          @timeout = timeout
        end

        def upload(url: nil, data_base64: nil, mime_type: nil, media_category: nil, alt_text: nil)
          bytes, mime = load_bytes(url: url, data_base64: data_base64, mime_type: mime_type)
          category = resolve_category(mime, media_category)
          check_size!(category, bytes.bytesize)
          text = normalize_alt_text(alt_text)

          data = if chunked?(category, bytes.bytesize)
                   chunked_upload(bytes, mime, category)
                 else
                   simple_upload(bytes, category)
                 end
          create_metadata(data["id"], text) if text
          result_hash(data, category, bytes.bytesize)
        end

        private

        def load_bytes(url:, data_base64:, mime_type:)
          url = url.to_s.strip
          encoded = data_base64.to_s.strip
          raise Client::Error, "url or data_base64 is required" if url.empty? && encoded.empty?
          raise Client::Error, "pass url or data_base64, not both" if !url.empty? && !encoded.empty?

          if !url.empty?
            hinted = mime_type.to_s.strip
            hinted = mime_from_url(url) if hinted.empty?
            downloaded, detected = download(url, hinted_mime: hinted)
            mime = hinted
            mime = detected if mime.empty?
            [downloaded, normalize_mime(mime)]
          else
            raise Client::Error, "mime_type is required with data_base64" if mime_type.to_s.strip.empty?
            raise Client::Error, "data_base64 is not valid base64" unless encoded.match?(/\A[A-Za-z0-9+\/=\s]+\z/)

            bytes = Base64.decode64(encoded)
            raise Client::Error, "data_base64 is empty" if bytes.bytesize.zero?

            [bytes, normalize_mime(mime_type)]
          end
        end

        def normalize_mime(value)
          mime = value.to_s.split(";").first.to_s.strip.downcase
          canonical = MIME_TYPES[mime]
          return canonical if canonical

          raise Client::Error,
                "unsupported media format #{mime.inspect}. Use jpg, png, webp, gif, mp4, webm, or quicktime."
        end

        def resolve_category(mime, explicit)
          inferred = CATEGORY_FOR_MIME.fetch(mime)
          category = explicit.to_s.strip
          category = inferred if category.empty?
          unless CATEGORIES.include?(category)
            raise Client::Error, "unsupported media_category #{category.inspect}. Use tweet_image, tweet_gif, or tweet_video."
          end
          if category != inferred
            raise Client::Error, "media_category #{category} does not match #{mime}"
          end

          category
        end

        def check_size!(category, bytesize)
          limit = { "tweet_image" => IMAGE_LIMIT, "tweet_gif" => GIF_LIMIT, "tweet_video" => VIDEO_LIMIT }.fetch(category)
          return if bytesize <= limit

          raise Client::Error, "file too large (#{bytesize} bytes, max #{limit} for #{category})"
        end

        def chunked?(category, bytesize)
          return true if category == "tweet_video"

          category == "tweet_gif" && bytesize > IMAGE_LIMIT
        end

        def normalize_alt_text(value)
          text = value.to_s
          return nil if text.strip.empty?
          if text.length > ALT_TEXT_LIMIT
            raise Client::Error, "alt_text is too long (#{text.length} characters, max #{ALT_TEXT_LIMIT})"
          end

          text
        end

        def simple_upload(bytes, category)
          result = media_post(
            "media/upload",
            body: {
              "media" => Base64.strict_encode64(bytes),
              "media_category" => category,
            },
          )
          wait_until_ready(data_of(result, "upload"))
        end

        def chunked_upload(bytes, mime, category)
          init = media_post(
            "media/upload/initialize",
            body: {
              "media_type" => mime,
              "total_bytes" => bytes.bytesize,
              "media_category" => category,
            },
          )
          data = data_of(init, "initialize")
          media_id = data["id"].to_s
          raise Client::Error, "Twitter media initialize did not return an id" unless media_id.match?(/\A[0-9]{1,19}\z/)

          offset = 0
          segment = 0
          while offset < bytes.bytesize
            chunk = bytes.byteslice(offset, CHUNK_BYTES)
            media_post(
              "media/upload/#{media_id}/append",
              body: {
                "segment_index" => segment,
                "media" => Base64.strict_encode64(chunk),
              },
            )
            offset += chunk.bytesize
            segment += 1
          end

          finalized = media_post("media/upload/#{media_id}/finalize")
          wait_until_ready(data_of(finalized, "finalize"))
        end

        def wait_until_ready(data)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STATUS_BUDGET
          polls = 0
          loop do
            info = data["processing_info"]
            state = info.is_a?(Hash) ? info["state"].to_s : ""
            return data if state.empty? || state == "succeeded"
            if state == "failed"
              raise Client::Error, "media processing failed: #{x_message(info)}"
            end
            unless %w[pending in_progress].include?(state)
              raise Client::Error, "unexpected media processing state #{state.inspect}: #{x_message(info)}"
            end

            polls += 1
            if polls > MAX_STATUS_POLLS || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              raise Client::Error, "media processing timed out (last state #{state})"
            end

            pause(info["check_after_secs"])
            status = media_get(
              "media/upload",
              query: { "command" => "STATUS", "media_id" => data["id"] },
            )
            data = data_of(status, "status")
          end
        end

        def create_metadata(media_id, text)
          media_post(
            "media/metadata",
            body: {
              "id" => media_id.to_s,
              "metadata" => { "alt_text" => { "text" => text } },
            },
          )
        end

        def result_hash(data, category, bytesize)
          result = {
            "media_id" => data["id"].to_s,
            "media_key" => data["media_key"],
            "type" => category,
            "size" => data["size"] || bytesize,
          }
          result["expires_after_secs"] = data["expires_after_secs"] if data.key?("expires_after_secs")
          result
        end

        def media_post(path, body: nil)
          interpret(@client.post(path, body: body, raise_on_error: false, api_base: Client::MEDIA_BASE), path)
        end

        def media_get(path, query:)
          interpret(@client.get(path, query: query, raise_on_error: false, api_base: Client::MEDIA_BASE), path)
        end

        def interpret(result, context)
          status = result[:status].to_i
          return result if status.between?(200, 299)

          detail = x_message(result[:body])
          if status == 429
            retry_after = result[:headers].to_h["retry-after"]
            suffix = retry_after ? " retry-after=#{retry_after}" : ""
            raise Client::Error, "Twitter rate limit (#{context}): #{detail}#{suffix}"
          end
          if [401, 403].include?(status) && detail.match?(/scope|media\.write/i)
            raise Client::Error,
                  "Twitter token is missing the media.write scope. Re-authorize this instance. X said: #{detail}"
          end
          if status == 413 || detail.match?(/file (size|too large)|too large|exceeds/i)
            raise Client::Error, "file too large: #{detail}"
          end
          if detail.match?(/unsupported|media type|invalid media|format/i)
            raise Client::Error, "unsupported media format: #{detail}"
          end

          raise Client::Error, "Twitter API #{status} (#{context}): #{detail}"
        end

        def data_of(result, context)
          body = result[:body]
          data = body.is_a?(Hash) ? body["data"] : nil
          return data if data.is_a?(Hash) && data["id"].to_s != ""

          raise Client::Error, "Twitter media #{context} response missing data: #{x_message(body)}"
        end

        def x_message(body)
          case body
          when Hash
            parts = []
            parts << body["detail"] if body["detail"].present?
            parts << body["title"] if parts.empty? && body["title"].present?
            parts << body["message"] if body["message"].present?
            if body["error"].is_a?(Hash)
              parts << body["error"]["message"]
              parts << body["error"]["name"]
            elsif body["error"].present?
              parts << body["error"].to_s
            end
            if body["errors"].is_a?(Array)
              body["errors"].each do |item|
                parts << (item.is_a?(Hash) ? (item["message"] || item["detail"] || item["title"]) : item.to_s)
              end
            end
            text = parts.compact.reject { |part| part.to_s.strip.empty? }.join("; ")
            text.empty? ? JSON.generate(body) : text
          when String
            body
          else
            body.to_s
          end
        end

        def pause(seconds)
          wait = seconds.to_i
          return if wait <= 0

          @sleeper.call([wait, 15].min)
        end

        def download(url, hinted_mime:)
          fetch(parse_url(url), redirects: 0, hinted_mime: hinted_mime)
        end

        def parse_url(url)
          uri = URI.parse(url)
          unless uri.is_a?(URI::HTTPS) && uri.host.present?
            raise Client::Error, "url must be an https URL"
          end
          raise Client::Error, "url host is not allowed" if blocked_host?(uri.host)

          uri
        rescue URI::InvalidURIError => e
          raise Client::Error, "url is invalid: #{e.message}"
        end

        def fetch(uri, redirects:, hinted_mime:)
          Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: true,
            open_timeout: http_timeout,
            read_timeout: http_timeout,
            write_timeout: http_timeout,
          ) do |http|
            request = Net::HTTP::Get.new(uri)
            request["Accept"] = "*/*"
            request["User-Agent"] = "emcp-twitter"
            http.request(request) do |response|
              if response.is_a?(Net::HTTPRedirection)
                raise Client::Error, "media download failed: too many redirects" if redirects >= MAX_REDIRECTS

                location = response["location"].to_s
                raise Client::Error, "media download failed: redirect missing location" if location.empty?

                target = URI.join(uri, location)
                raise Client::Error, "media download redirect must stay on https" unless target.is_a?(URI::HTTPS)
                raise Client::Error, "url host is not allowed" if blocked_host?(target.host)

                return fetch(target, redirects: redirects + 1, hinted_mime: hinted_mime)
              end

              unless response.is_a?(Net::HTTPSuccess)
                raise Client::Error, "media download failed: HTTP #{response.code}"
              end

              header_mime = response["content-type"].to_s.split(";").first.to_s.strip.downcase
              mime = MIME_TYPES.key?(header_mime) ? header_mime : hinted_mime.to_s
              limit = download_limit(mime)
              length = response["content-length"].to_i
              if length.positive? && length > limit
                raise Client::Error, "file too large (#{length} bytes, max #{limit})"
              end

              chunks = []
              size = 0
              response.read_body do |chunk|
                size += chunk.bytesize
                if size > limit
                  raise Client::Error, "file too large (#{size} bytes, max #{limit})"
                end
                chunks << chunk
              end
              body = chunks.join
              raise Client::Error, "media download failed: empty body" if body.bytesize.zero?

              detected = MIME_TYPES.key?(header_mime) ? header_mime : nil
              return [body, detected]
            end
          end
        rescue Timeout::Error, SocketError, SystemCallError => e
          raise Client::Error, "media download failed: #{e.message}"
        end

        def download_limit(mime)
          canonical = MIME_TYPES[mime]
          case CATEGORY_FOR_MIME[canonical]
          when "tweet_image" then IMAGE_LIMIT
          when "tweet_gif" then GIF_LIMIT
          when "tweet_video" then VIDEO_LIMIT
          else GIF_LIMIT
          end
        end

        def mime_from_url(url)
          path = URI.parse(url).path
          EXTENSIONS[File.extname(path).downcase].to_s
        rescue URI::InvalidURIError
          ""
        end

        def blocked_host?(host)
          name = host.to_s.downcase
          return true if name.empty? || name == "localhost" || name.end_with?(".localhost", ".local")
          return true if name == "metadata.google.internal"

          ip = IPAddr.new(name)
          ip.loopback? || ip.private? || ip.link_local?
        rescue IPAddr::InvalidAddressError
          false
        end

        def http_timeout
          return @timeout if @timeout&.positive?

          seconds = ENV.fetch("TWITTER_TIMEOUT", "30").to_i
          seconds.positive? ? seconds : 30
        end
      end
    end
  end
end
