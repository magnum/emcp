# frozen_string_literal: true

class ContextStatusMailer < ApplicationMailer
  def unauthenticated(context, failures, healthy = [])
    @context = context
    @failures = failures
    @healthy = healthy
    count = failures.size
    noun = count == 1 ? "server is" : "servers are"

    mail(
      to: context.user.email,
      subject: "EmCP: #{count} #{noun} disconnected in #{context.name}",
    )
  end
end
