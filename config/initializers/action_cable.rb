# frozen_string_literal: true

# The Chrome extension connects from chrome-extension://, which is not this
# app's origin. The cable connection still requires a pairing token.
Rails.application.config.action_cable.disable_request_forgery_protection = true
