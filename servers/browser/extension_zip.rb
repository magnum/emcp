# frozen_string_literal: true

require "zlib"
require "stringio"

module Emcp
  module Servers
    module Browser
      # Stored-method zip of servers/browser/extension. No extra gem.
      class ExtensionZip
        ROOT = File.expand_path("extension", __dir__)

        def self.build
          files = Dir.glob(File.join(ROOT, "**", "*")).select { |path| File.file?(path) }
          raise "browser extension source is empty" if files.empty?

          entries = files.map do |path|
            [path.delete_prefix("#{ROOT}/"), File.binread(path)]
          end
          store(entries)
        end

        def self.store(entries)
          io = StringIO.new
          io.set_encoding(Encoding::BINARY)
          central = +""
          offset = 0
          entries.each do |name, data|
            name_bytes = name.b
            crc = Zlib.crc32(data)
            local = [
              0x04034b50, 20, 0, 0, 0, 0, crc, data.bytesize, data.bytesize, name_bytes.bytesize, 0,
            ].pack("VvvvvvVVVvv") + name_bytes
            io.write(local)
            io.write(data)
            central << [
              0x02014b50, 20, 20, 0, 0, 0, 0, crc, data.bytesize, data.bytesize,
              name_bytes.bytesize, 0, 0, 0, 0, 0, offset,
            ].pack("VvvvvvvVVVvvvvvVV") + name_bytes
            offset = io.string.bytesize
          end
          io.write(central)
          io.write([
            0x06054b50, 0, 0, entries.size, entries.size, central.bytesize, offset, 0,
          ].pack("VvvvvVVv"))
          io.string
        end
      end
    end
  end
end
