# frozen_string_literal: true

class ContextStatusMailer < ApplicationMailer
  def unauthenticated(context, servers)
    @context = context
    @servers = servers
    count = servers.size
    noun = count == 1 ? "server is" : "servers are"

    mail(
      to: context.user.email,
      subject: "EmCP: #{count} #{noun} disconnected in #{context.name}",
    )
  end
end
