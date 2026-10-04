# frozen_string_literal: true

namespace :browser do
  desc "Write tmp/emcp-browser-extension.zip for unpacked Chrome loading"
  task extension: :environment do
    require Rails.root.join("servers/browser/extension_zip")
    destination = Rails.root.join("tmp/emcp-browser-extension.zip")
    FileUtils.mkdir_p(destination.dirname)
    File.binwrite(destination, Emcp::Servers::Browser::ExtensionZip.build)
    puts destination
  end
end
