# frozen_string_literal: true

require "test_helper"

class ContextsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
  end

  test "index requires session" do
    get contexts_path
    assert_response :redirect
  end

  test "index lists contexts and underlines Contexts" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    create_context!(name: "House")
    hey = mcp_server_for("hey")
    hey.update!(name: "HEY work inbox")

    get contexts_path
    assert_equal "/contexts", contexts_path
    assert_response :success
    assert_match(/House/, response.body)
    refute_includes response.body, hey.name
    assert_select "a[href=?]", mcp_servers_path, text: "Servers"
    assert_select "a[href=?]", contexts_path, text: "Contexts"
    assert_select "a.underline", text: "Contexts"
    assert_select "a.underline", text: "Servers", count: 0
  end

  test "new is a context form without a type picker" do
    post sign_in_path, params: { email: @user.email, password: "password123" }

    get new_context_path
    assert_response :success
    assert_select "form[action=?]", contexts_path
    assert_select "select#mcp_server_mcp_server_type_id", count: 0
  end

  test "create builds a context and goes to the hub page" do
    post sign_in_path, params: { email: @user.email, password: "password123" }

    assert_difference -> { @user.mcp_servers.contexts.count }, 1 do
      post contexts_path, params: {
        mcp_server: { name: "Work", description: "office", tag_list: "office" }
      }
    end
    context = @user.mcp_servers.contexts.order(:id).last
    assert_equal "Work", context.name
    assert context.context?
    assert_redirected_to mcp_server_path(context)
  end
end
