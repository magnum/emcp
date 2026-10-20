# frozen_string_literal: true

require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    @user = users(:one)
    @other = users(:two)
  end

  test "profile offers a test email to the signed-in user" do
    post sign_in_path, params: { email: @user.email, password: "password123" }

    get user_path(@user)

    assert_response :success
    assert_select "form[action=?]", test_email_user_path(@user)
    assert_select "button", text: "Send test email"
  end

  test "test email is delivered to that user" do
    post sign_in_path, params: { email: @user.email, password: "password123" }

    assert_emails 1 do
      post test_email_user_path(@user)
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal [ @user.email ], mail.to
    assert_equal "EmCP: test email", mail.subject
    assert_redirected_to user_path(@user)
    follow_redirect!
    assert_match "Test email sent to #{@user.email}", response.body
  end

  test "a user cannot send a test email for someone else" do
    post sign_in_path, params: { email: @user.email, password: "password123" }

    assert_no_emails do
      post test_email_user_path(@other)
    end

    assert_redirected_to root_path
  end
end
