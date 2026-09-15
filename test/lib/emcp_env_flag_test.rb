# frozen_string_literal: true

require "test_helper"

class EmcpEnvFlagTest < ActiveSupport::TestCase
  teardown { ENV.delete("EMCP_FLAG_TEST") }

  test "treats only 1/true/yes/on as enabled" do
    {
      nil => false,
      "" => false,
      "false" => false,
      "0" => false,
      "off" => false,
      "no" => false,
      "true" => true,
      "TRUE" => true,
      "1" => true,
      "yes" => true,
      "on" => true
    }.each do |value, expected|
      if value.nil?
        ENV.delete("EMCP_FLAG_TEST")
      else
        ENV["EMCP_FLAG_TEST"] = value
      end

      assert_equal expected, Emcp.env_flag?("EMCP_FLAG_TEST"), "expected #{value.inspect} => #{expected}"
    end
  end

  test "uses the given default when the key is missing" do
    ENV.delete("EMCP_FLAG_TEST")
    assert Emcp.env_flag?("EMCP_FLAG_TEST", default: true)
  end
end
