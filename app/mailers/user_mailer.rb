# frozen_string_literal: true

class UserMailer < ApplicationMailer
  def test_message(user)
    @user = user

    mail(
      to: user.email,
      subject: "EmCP: test email",
    )
  end
end
