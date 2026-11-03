class ApplicationMailer < ActionMailer::Base
  # Read at delivery time. SMTP_FROM must be a sender verified in Brevo;
  # the SMTP login (…@smtp-brevo.com) is only the relay account.
  default from: -> {
    from = ENV["SMTP_FROM"].to_s.strip
    from = ENV["SMTP_USERNAME"].to_s.strip if from.empty?
    from.presence || "from@example.com"
  }
  layout "mailer"
end
