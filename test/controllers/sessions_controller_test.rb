# frozen_string_literal: true

require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "sign in page has email form" do
    get sign_in_path

    assert_response :success
    assert_select "form"
  end

  test "hides google button when oauth is not configured" do
    previous_id = ENV["GOOGLE_CLIENT_ID"]
    previous_secret = ENV["GOOGLE_CLIENT_SECRET"]
    ENV.delete("GOOGLE_CLIENT_ID")
    ENV.delete("GOOGLE_CLIENT_SECRET")

    get sign_in_path

    assert_response :success
    assert_select "a[href='/auth/google_oauth2']", count: 0
  ensure
    ENV["GOOGLE_CLIENT_ID"] = previous_id if previous_id
    ENV["GOOGLE_CLIENT_SECRET"] = previous_secret if previous_secret
  end

  test "shows google button when oauth is configured" do
    previous_id = ENV["GOOGLE_CLIENT_ID"]
    previous_secret = ENV["GOOGLE_CLIENT_SECRET"]
    ENV["GOOGLE_CLIENT_ID"] = "test-google-client-id"
    ENV["GOOGLE_CLIENT_SECRET"] = "test-google-client-secret"

    get sign_in_path

    assert_response :success
    assert_select "a[href='/auth/google_oauth2']", text: /Connect with Google/
  ensure
    if previous_id
      ENV["GOOGLE_CLIENT_ID"] = previous_id
    else
      ENV.delete("GOOGLE_CLIENT_ID")
    end
    if previous_secret
      ENV["GOOGLE_CLIENT_SECRET"] = previous_secret
    else
      ENV.delete("GOOGLE_CLIENT_SECRET")
    end
  end

  test "oauth failure redirects to sign in" do
    get auth_failure_path

    assert_redirected_to sign_in_path
  end
end
