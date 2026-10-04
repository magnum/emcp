# frozen_string_literal: true

require "test_helper"

class BrowserOriginPolicyTest < ActiveSupport::TestCase
  test "a blank allowlist allows every https url" do
    policy = Emcp::Servers::Browser::OriginPolicy.new(nil)

    assert_equal ["https://*/*"], policy.origins
    assert policy.allows_url?("https://edma.example.it/home")
    assert policy.allows_url?("https://other.example/path")
    refute policy.allows_url?("http://edma.example.it/home")
  end

  test "comma-separated chrome patterns match those sites only" do
    policy = Emcp::Servers::Browser::OriginPolicy.new(
      "https://edma.example.it/*, *.files.example.it, http://127.0.0.1:3000/*",
    )

    assert policy.allows_url?("https://edma.example.it/pratiche")
    assert policy.allows_url?("https://cdn.files.example.it/download")
    assert policy.allows_url?("http://files.example.it/download")
    assert policy.allows_url?("http://127.0.0.1:3000/up")
    refute policy.allows_url?("https://127.0.0.1:3000/up")
    refute policy.allows_url?("http://127.0.0.1:4000/up")
    refute policy.allows_url?("https://other.example/edma.example.it")
    refute policy.allows_url?("https://edma.example.it.evil.test/")
    refute policy.allows_url?("https://files.example.it.evil.test/")
  end
end
