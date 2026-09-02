# frozen_string_literal: true

require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "guests see the app name on the home page" do
    get root_path

    assert_response :success
    assert_select "h1", text: Settings.app.name
    assert_select "footer a[href=?]", "/privacy-policy"
  end

  test "signed in users are sent to integrations" do
    user = users(:one)
    post sign_in_path, params: { email: user.email, password: "password123" }

    get root_path

    assert_redirected_to mcp_servers_path
  end
end
