# frozen_string_literal: true

namespace :emcp do
  desc "Remove leftover storage/mcp/* directories except instances/"
  task purge_legacy_mcp_storage: :environment do
    removed = McpServer.purge_legacy_storage!
    if removed.empty?
      puts "No leftover storage/mcp directories to remove."
    else
      puts "Removed: #{removed.sort.join(', ')}"
    end
  end
end
