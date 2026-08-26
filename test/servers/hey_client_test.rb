# frozen_string_literal: true

require "test_helper"
require Rails.root.join("servers/hey/hey_client").to_s

class HeyClientTest < ActiveSupport::TestCase
  setup do
    @client = Emcp::Servers::Hey::Client.new
  end

  test "boxes lists mailboxes with hey box list" do
    assert_equal %w[box list --json], @client.boxes
    assert_equal %w[box list --json --limit 10], @client.boxes(limit: 10)
  end

  test "box still addresses a mailbox by name" do
    assert_equal %w[box imbox --json], @client.box("imbox")
  end
end
