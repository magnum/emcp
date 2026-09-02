ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.

# Load .env before Rails. Requiring dotenv here (before Rails::Railtie exists)
# skips dotenv's Rails integration, so we must load files ourselves.
# Does not override variables already set (Kamal secrets, APP_HOST, …).
# Production also reads /rails/storage/.env from the Kamal volume.
begin
  require "dotenv"
  root = File.expand_path("..", __dir__)
  files = [
    File.join(root, ".env"),
    File.join(root, "storage/.env"),
  ]
  Dotenv.load(*files.select { |path| File.file?(path) })
rescue LoadError
  # dotenv not bundled (e.g. incomplete install) — skip
end
