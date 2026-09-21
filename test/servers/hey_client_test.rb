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
    assert_equal(
      [ "compose", "--subject", "Board", "-m", "Numbers.", "--to", "a@b.com", "--from", "billing@example.org", "--no-name-tag", "--json" ],
      @client.compose(subject: "Board", message: "Numbers.", to: "a@b.com", from: "billing@example.org", no_name_tag: true),
    )
  end

  test "reply and forward accept Markdown or HTML" do
    assert_equal %w[reply 99 -m Thanks --json], @client.reply("99", message: "Thanks")
    assert_equal %w[forward 99 --to a@b.com --message-html <p>FYI</p> --json], @client.forward("99", to: "a@b.com", message_html: "<p>FYI</p>")
  end

  test "does not pass --limit on commands hey-cli 1.6.0 rejects" do
    assert_equal %w[workflow view 654 --json], @client.workflow("654")
    refute_includes @client.screener_history(page: "cursor"), "--limit"
    assert_equal %w[screener history --page cursor --json], @client.screener_history(page: "cursor")
    assert_equal %w[screener history --all --json], @client.screener_history(fetch_all: true)
    assert_equal %w[screener list --page cursor --json], @client.screener(page: "cursor")
    refute_includes @client.screener(fetch_all: true), "--limit"
    assert_equal %w[search q --all --json], @client.search("q", fetch_all: true)
    refute_includes @client.search("q", page: "n"), "--limit"
    assert_equal %w[contact list --page 2 --json], @client.contacts(page: "2")
    refute_includes @client.contacts(fetch_all: true), "--limit"
  end

  test "account senders, draft from, and occurrence edits use 1.6.0 flags" do
    assert_equal %w[account senders --json], @client.account_senders
    assert_equal %w[--account 99 account senders --json], @client.account_senders(account: "99")
    assert_equal(
      %w[draft edit 44 --from billing@example.org --json],
      @client.draft_edit("44", from: "billing@example.org"),
    )
    assert_equal(
      %w[event edit 4821 --start-time 15:00 --occurrence 4821_2026-09-15 --apply-to current --json],
      @client.event_edit("4821", occurrence: "4821_2026-09-15", apply_to: "current", start_time: "15:00"),
    )
    assert_equal(
      %w[event edit 4821 --title Design\ review\ (v2) --occurrence 4821_2026-09-15 --apply-to future --repeat every_week --repeat-times 8 --allow-plain-notes --json],
      @client.event_edit(
        "4821",
        occurrence: "4821_2026-09-15",
        apply_to: "future",
        repeat: "every_week",
        repeat_times: "8",
        title: "Design review (v2)",
        allow_plain_notes: true,
      ),
    )
  end

  test "organization commands take posting ids or topic ids as the CLI requires" do
    assert_equal %w[label add 1 --to 789 --json], @client.label_add("1", to: "789")
    assert_equal %w[collection add 987 --to 321 --json], @client.collection_add("987", to: "321")
    assert_equal %w[move 1 2 --to feed --json], @client.move(%w[1 2], to: "feed")
    assert_equal %w[bubble up 1 --weekend --json], @client.bubble_up("1", weekend: true)
    assert_equal %w[screener approve 91 --box The\ Feed --json], @client.screener_approve("91", box: "The Feed")
  end
end
