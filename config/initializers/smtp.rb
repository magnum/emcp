# frozen_string_literal: true

# Test keeps delivery_method :test. This file loads after the environment
# configs, so an unconditional smtp assignment would swallow test deliveries.
return if Rails.env.test?

host = ENV["SMTP_HOST"].to_s.strip
return if host.empty?

ActionMailer::Base.delivery_method = :smtp
ActionMailer::Base.raise_delivery_errors = true
ActionMailer::Base.smtp_settings = {
  address: host,
  port: Integer(ENV.fetch("SMTP_PORT", "587")),
  user_name: ENV["SMTP_USERNAME"].presence,
  password: ENV["SMTP_PASSWORD"].presence,
  authentication: :plain,
  enable_starttls_auto: true,
}

# From is set on ApplicationMailer so it is not overridden by that class default.
