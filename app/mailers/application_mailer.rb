class ApplicationMailer < ActionMailer::Base
  # Read at delivery time. Must be an address on a domain verified in Resend.
  default from: -> {
    from = ENV["SMTP_FROM"].to_s.strip
    from.presence || "EmCP <service@emcp.it>"
  }
  layout "mailer"
end
