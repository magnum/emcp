# frozen_string_literal: true

require "test_helper"

class MainViewsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.add_role(:admin)
    @server = mcp_server_for("hey", user: @user)
    @context = create_context!(user: @user, name: "House view", servers: [ @server ])
    @whatsapp = mcp_server_for("whatsapp", user: @user)
    @hook = @whatsapp.whatsapp_hooks.create!(url: "https://example.com/hook", secret: "supersecret")
    @webhook = @hook.webhook!(
      :post,
      @hook.url,
      body: "{}",
      headers: { "Content-Type" => "application/json" },
      async: true,
    )
  end

  test "public pages render" do
    invitation = invitations(:one)
    invitation.update_columns(state: "created")
    cookies["emcp_invitation"] = "#{invitation.id},#{invitation.signature}"

    assert_pages(
      root_path,
      sign_in_path,
      sign_up_path,
      invitation_consume_path,
      invitation_consume_with_code_path(invitations(:one).code),
      "/privacy-policy",
      "/it/privacy-policy",
      "/terms-and-conditions",
      "/it/terms-and-conditions",
      "/cookie-policy",
      "/it/cookie-policy",
    )
  end

  test "signed-in pages render" do
    sign_in

    assert_pages(
      mcp_servers_path,
      new_mcp_server_path,
      mcp_server_path(@server),
      edit_mcp_server_path(@server),
      auth_mcp_server_path(@context),
      contexts_path,
      new_context_path,
      mcp_server_path(@context),
      edit_mcp_server_path(@context),
      mcp_server_path(@whatsapp),
      new_mcp_server_webhook_path(@whatsapp),
      mcp_server_edit_webhook_path(@whatsapp, @hook),
      users_path,
      user_path(@user),
      edit_user_path(@user),
    )

    get mcp_server_path(@whatsapp)
    assert_response :success
    assert_includes response.body, "https://example.com/hook"
    refute_includes response.body, "supersecret"
    refute_includes response.body, "Messages history"

    get mcp_server_edit_webhook_path(@whatsapp, @hook)
    assert_response :success
    assert_includes response.body, "Messages history"
    refute_includes response.body, "supersecret"
  end

  test "admin pages render" do
    sign_in
    type = McpServerType.find_by!(code: "hey")

    assert_pages(
      admin_root_path,
      admin_users_path,
      new_admin_user_path,
      admin_user_path(@user),
      edit_admin_user_path(@user),
      admin_roles_path,
      new_admin_role_path,
      admin_role_path(roles(:admin)),
      edit_admin_role_path(roles(:admin)),
      admin_api_keys_path,
      new_admin_api_key_path,
      admin_api_key_path(api_keys(:one)),
      edit_admin_api_key_path(api_keys(:one)),
      admin_mcp_server_types_path,
      new_admin_mcp_server_type_path,
      admin_mcp_server_type_path(type),
      edit_admin_mcp_server_type_path(type),
      admin_mcp_servers_path,
      new_admin_mcp_server_path,
      admin_mcp_server_path(@server),
      edit_admin_mcp_server_path(@server),
      admin_mcp_server_path(@whatsapp),
      admin_plan_types_path,
      new_admin_plan_type_path,
      admin_plan_type_path(plan_types(:one)),
      edit_admin_plan_type_path(plan_types(:one)),
      admin_plans_path,
      new_admin_plan_path,
      admin_plan_path(plans(:one)),
      edit_admin_plan_path(plans(:one)),
      admin_invitations_path,
      new_admin_invitation_path,
      admin_invitation_path(invitations(:one)),
      edit_admin_invitation_path(invitations(:one)),
      admin_webhooks_path,
      new_admin_webhook_path,
      admin_webhook_path(@webhook),
      edit_admin_webhook_path(@webhook),
    )
  end

  private

  def sign_in
    post sign_in_path, params: { email: @user.email, password: "password123" }
  end

  def assert_pages(*paths)
    failures = paths.filter_map do |path|
      get path
      next if response.successful?

      "#{path} -> #{response.status}"
    end
    assert_empty failures, failures.join("\n")
  end
end
