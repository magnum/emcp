# frozen_string_literal: true

require "test_helper"
require Rails.root.join("servers/hey/hey_client").to_s

class HeyClientTest < ActiveSupport::TestCase
  setup do
    @client = Emcp::Servers::Hey::Client.new
  end

  test "boxes lists mailboxes with hey box list" do
    assert_equal %w[box list --json], @client.boxes
    assert_equal %w[box list --limit 10 --json], @client.boxes(limit: 10)
    assert_equal %w[--account 12345 box list --json], @client.boxes(account: "12345")
  end

  test "box views a mailbox by name" do
    assert_equal %w[box view imbox --json], @client.box("imbox")
    assert_equal %w[box view imbox --page next-cursor --all --json], @client.box("imbox", fetch_all: true, page: "next-cursor")
  end

  test "threads reads a topic with hey thread read" do
    assert_equal %w[thread read 99 --json], @client.threads("99")
    assert_equal %w[thread read 99 --html --allow-partial --json], @client.threads("99", html: true, allow_partial: true)
  end

  test "drafts use hey draft list" do
    assert_equal %w[draft list --json], @client.drafts
    assert_equal %w[draft show 44 --json], @client.draft_show("44")
  end

  test "calendars and events use noun-first commands" do
    assert_equal %w[calendar list --json], @client.calendars
    assert_equal %w[event list --calendar 123 --starts-on 2026-09-01 --json], @client.events(calendar_id: "123", starts_on: "2026-09-01")
    assert_equal %w[event day 2026-09-02 --json], @client.event_day("2026-09-02")
    assert_equal %w[event week --json], @client.event_week
  end

  test "search uses the official CLI instead of a local box scan" do
    assert_equal(
      %w[search quarterly --from jane@example.com --date last_30_days --in imbox --json],
      @client.search("quarterly", from: "jane@example.com", date: "last_30_days", inbox: "imbox"),
    )
    assert_equal %w[search filters --json], @client.search_filters
  end

  test "compose sends Markdown with -m and HTML with --message-html" do
    assert_equal(
      [ "compose", "--subject", "Hi", "-m", "We **shipped** it.", "--to", "a@b.com", "--json" ],
      @client.compose(subject: "Hi", message: "We **shipped** it.", to: "a@b.com"),
    )
    assert_equal(
      [ "compose", "--subject", "Hi", "--message-html", "<p>Hi</p>", "--draft", "--json" ],
      @client.compose(subject: "Hi", message_html: "<p>Hi</p>", draft: true),
    )
  end

  test "reply and forward accept Markdown or HTML" do
    assert_equal %w[reply 99 -m Thanks --json], @client.reply("99", message: "Thanks")
    assert_equal %w[forward 99 --to a@b.com --message-html <p>FYI</p> --json], @client.forward("99", to: "a@b.com", message_html: "<p>FYI</p>")
  end

  test "organization commands take posting ids or topic ids as the CLI requires" do
    assert_equal %w[label add 1 --to 789 --json], @client.label_add("1", to: "789")
    assert_equal %w[collection add 987 --to 321 --json], @client.collection_add("987", to: "321")
    assert_equal %w[move 1 2 --to feed --json], @client.move(%w[1 2], to: "feed")
    assert_equal %w[bubble up 1 --weekend --json], @client.bubble_up("1", weekend: true)
    assert_equal %w[screener approve 91 --box The\ Feed --json], @client.screener_approve("91", box: "The Feed")
  end
end
