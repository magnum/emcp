# frozen_string_literal: true

require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "from_omniauth links an existing user with the same email" do
    user = users(:one)

    linked = User.from_omniauth(google_auth(email: user.email.upcase, uid: "google-one"))

    assert_equal user.id, linked.id
    assert_equal 2, User.count
    assert_equal "Test", linked.firstname
    assert_equal "google_oauth2", linked.provider
    assert_equal "google-one", linked.uid
    assert linked.google_connected?
    assert_equal "https://example.com/avatar.png", linked.avatar_url
  end

  test "from_omniauth reuses the same google identity" do
    user = users(:one)
    user.update!(provider: "google_oauth2", uid: "google-one")

    linked = User.from_omniauth(google_auth(email: "other-#{user.email}", uid: "google-one"))

    assert_equal user.id, linked.id
    assert_equal 2, User.count
  end

  test "from_omniauth creates a user only when email and google id are new" do
    assert_difference -> { User.count }, 1 do
      User.from_omniauth(google_auth(email: "new-google@example.com", uid: "google-new"))
    end
  end

  private

  def google_auth(email:, uid:)
    OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid,
      info: {
        email: email,
        first_name: "Google",
        last_name: "Person",
        image: "https://example.com/avatar.png",
      },
    )
  end
end
