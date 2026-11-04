# frozen_string_literal: true

# Test keeps delivery_method :test. This file loads after the environment
# configs, so an unconditional assignment would swallow test deliveries.
return if Rails.env.test?

Resend.api_key = -> { Rails.application.credentials.dig(:resend, :api_key).to_s.strip.presence }

ActionMailer::Base.delivery_method = :resend
ActionMailer::Base.raise_delivery_errors = true
