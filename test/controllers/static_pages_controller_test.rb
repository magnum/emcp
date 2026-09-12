# frozen_string_literal: true

require "test_helper"

class StaticPagesControllerTest < ActionDispatch::IntegrationTest
  test "privacy policy without locale uses english view" do
    get "/privacy-policy"

    assert_response :success
    assert_match "Privacy policy", response.body
    assert_match "Antonio Molinari", response.body
    assert_google_user_data_disclosures
  end

  test "privacy policy italian url" do
    get "/it/privacy-policy"

    assert_response :success
    assert_match "Informativa sulla privacy", response.body
    assert_google_user_data_disclosures
  end

  test "terms and conditions english and italian" do
    get "/terms-and-conditions"
    assert_response :success
    assert_match "Terms and conditions", response.body

    get "/it/terms-and-conditions"
    assert_response :success
    assert_match "Termini e condizioni", response.body
  end

  test "cookie policy english and italian" do
    get "/cookie-policy"
    assert_response :success
    assert_match "Cookie policy", response.body

    get "/it/cookie-policy"
    assert_response :success
    assert_match "Informativa cookie", response.body
  end

  test "legal pages include footer links" do
    get "/privacy-policy"

    assert_select "footer"
    assert_select "footer a[href=?]", "/privacy-policy"
    assert_select "footer a[href=?]", "/terms-and-conditions"
    assert_select "footer a[href=?]", "/cookie-policy"
    assert_select "footer", text: /#{Regexp.escape(Emcp.release_commit)}/ if Emcp.release_commit.present?
    assert_select "footer", text: /#{Regexp.escape(Emcp.release_tag)}/ if Emcp.release_tag.present?
  end

  test "existing app routes are not captured by static pages" do
    get sign_in_path

    assert_response :success
    assert_select "form"
  end

  private

  def assert_google_user_data_disclosures
    assert_select "h2#google-user-data"
    assert_select "h3#google-data-access"
    assert_select "h3#google-data-use"
    assert_select "h3#google-data-sharing"
    assert_select "h3#google-data-protection"
    assert_select "h3#google-data-retention"
  end
end
