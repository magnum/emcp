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

  test "google connect links an existing email without creating a user or needing an invitation" do
    user = users(:one)
    stub_google_oauth(email: user.email, uid: "google-one")

    assert_no_difference -> { User.count } do
      get "/auth/google_oauth2/callback"
    end

    assert_redirected_to root_path
    assert_equal user.id, session[:user_id]
    user.reload
    assert_equal "google_oauth2", user.provider
    assert_equal "google-one", user.uid
  ensure
    reset_google_oauth_stub
  end

  test "google connect still requires an invitation for a new email" do
    stub_google_oauth(email: "brand-new@example.com", uid: "google-new")

    assert_no_difference -> { User.count } do
      get "/auth/google_oauth2/callback"
    end

    assert_redirected_to root_path
    assert_equal I18n.t("views.invitations.requires_invitation"), flash[:alert]
    assert_nil session[:user_id]
  ensure
    reset_google_oauth_stub
  end

  private

  def stub_google_oauth(email:, uid:)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid,
      info: { email: email, first_name: "Google", last_name: "Person", image: "https://example.com/a.png" },
    )
  end

  def reset_google_oauth_stub
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end
end
