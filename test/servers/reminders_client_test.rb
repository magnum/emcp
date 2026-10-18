# frozen_string_literal: true

require "test_helper"
require "base64"

class RemindersClientTest < ActiveSupport::TestCase
  APPLE_ID = "user@icloud.com"
  APP_PASSWORD = "xxxx-xxxx-xxxx-xxxx"

  setup do
    @previous_list = ENV["REMINDERS_DEFAULT_LIST"]
    ENV.delete("REMINDERS_DEFAULT_LIST")
    @calls = []
    @client = Emcp::Servers::Reminders::Client.new(
      transport: method(:transport),
      apple_id: APPLE_ID,
      app_password: APP_PASSWORD,
      clock: -> { Time.utc(2026, 10, 18, 9, 0, 0) },
    )
  end

  teardown do
    if @previous_list.nil?
      ENV.delete("REMINDERS_DEFAULT_LIST")
    else
      ENV["REMINDERS_DEFAULT_LIST"] = @previous_list
    end
  end

  test "missing credentials fail before any request" do
    called = false
    client = Emcp::Servers::Reminders::Client.new(transport: ->(*) { called = true })

    error = assert_raises(Emcp::Servers::Reminders::Client::Error) { client.lists }

    assert_match "REMINDERS_APPLE_ID", error.message
    assert_equal false, called
  end

  test "lists keeps VTODO collections and skips event calendars" do
    rows = @client.lists

    assert_equal [ "Reminders" ], rows.map { |row| row["name"] }
    assert_equal "https://p01-caldav.icloud.com/1/calendars/reminders/", rows.first["id"]
    assert_equal true, rows.first["default"]
    assert_equal APPLE_ID, rows.first["account"]
    assert_equal "PROPFIND", @calls.first[:method]
    assert_equal "https://caldav.icloud.com/", @calls.first[:url]
    decoded = Base64.strict_decode64(@calls.first[:headers]["Authorization"].delete_prefix("Basic "))
    assert_equal "#{APPLE_ID}:#{APP_PASSWORD}", decoded
  end

  test "an empty calendar home reports the upgraded-list limit" do
    @lists_xml = empty_lists_xml

    status = @client.status

    assert_equal 0, status["lists"]
    assert_nil status["default_list"]
    assert_match "current Reminders format", status["warning"]
  end

  test "filters use apple priority and the completion date for completed reminders" do
    high = @client.reminders(is_completed: false, due_before: "2026-10-19T00:00:00Z", priority: "high")
    assert_equal [ "Milk" ], high["reminders"].map { |row| row["title"] }

    @client = fresh_client
    completed = @client.reminders(is_completed: true, due_after: "2026-10-17T00:00:00Z", due_before: "2026-10-18T00:00:00Z")
    assert_equal [ "Done" ], completed["reminders"].map { |row| row["title"] }

    @client = fresh_client
    searched = @client.reminders(query: "oat")
    assert_equal [ "Milk" ], searched["reminders"].map { |row| row["title"] }
    assert_equal "https://example.com/milk", searched["reminders"].first["url"]
  end

  test "next reminder is the earliest incomplete due on or after now" do
    upcoming = @client.next_reminder

    assert_equal "Milk", upcoming["title"]
    assert_equal "2026-10-18T10:00:00Z", upcoming["due_date"]
  end

  test "create writes a VTODO with apple priority and a URL" do
    created = @client.create_reminder(title: "Milk", notes: "oat", url: "https://example.com/milk", priority: "high")

    put = @calls.last
    assert_equal "PUT", put[:method]
    assert_match %r{/calendars/reminders/[0-9a-f-]+\.ics\z}, put[:url]
    assert_includes put[:body], "SUMMARY:Milk"
    assert_includes put[:body], "DESCRIPTION:oat"
    assert_includes put[:body], "URL:https://example.com/milk"
    assert_includes put[:body], "PRIORITY:1"
    assert_equal "Milk", created["title"]
    assert_equal 1, created["priority"]
    assert_equal "high", created["priority_name"]
  end

  test "create uses REMINDERS_DEFAULT_LIST only when the call omits a list" do
    ENV["REMINDERS_DEFAULT_LIST"] = "Errands"
    @lists_xml = lists_xml(extra: errands_list_xml)

    @client.create_reminder(title: "Milk")
    assert_match %r{/calendars/errands/}, @calls.last[:url]

    @client = fresh_client
    @client.create_reminder(title: "Bread", list_name: "Reminders")
    assert_match %r{/calendars/reminders/}, @calls.last[:url]
  end

  test "update changes the title and keeps the alarm description" do
    href = "https://p01-caldav.icloud.com/1/calendars/reminders/milk.ics"
    updated = @client.update_reminder(id: href, title: "Bread")

    put = @calls.find { |call| call[:method] == "PUT" }
    assert_equal href, put[:url]
    assert_includes put[:body], "SUMMARY:Bread"
    assert_includes put[:body], "DESCRIPTION:oat"
    assert_includes put[:body], "DESCRIPTION:alert"
    assert_equal "Bread", updated["title"]
    assert_equal "oat", updated["notes"]
  end

  test "priority names follow apple and low is 9" do
    assert_equal 1, Emcp::Servers::Reminders::Ics.priority_value("high")
    assert_equal 5, Emcp::Servers::Reminders::Ics.priority_value("medium")
    assert_equal 9, Emcp::Servers::Reminders::Ics.priority_value("low")
    assert_equal 0, Emcp::Servers::Reminders::Ics.priority_value("none")
    assert_equal "low", Emcp::Servers::Reminders::Ics.priority_name(9)
  end

  test "iCloud auth failure does not include the password" do
    @fail_status = 401

    error = assert_raises(Emcp::Servers::Reminders::Client::Error) { @client.lists }

    assert_match "HTTP 401", error.message
    assert_no_match APP_PASSWORD, error.message
  end

  private

  def fresh_client
    @calls = []
    Emcp::Servers::Reminders::Client.new(
      transport: method(:transport),
      apple_id: APPLE_ID,
      app_password: APP_PASSWORD,
      clock: -> { Time.utc(2026, 10, 18, 9, 0, 0) },
    )
  end

  def transport(method, url, headers, body)
    @calls << { method: method, url: url, headers: headers, body: body }
    return { status: @fail_status, headers: {}, body: "nope" } if @fail_status

    case method
    when "PROPFIND"
      { status: 207, headers: {}, body: propfind_body(url) }
    when "REPORT"
      { status: 207, headers: {}, body: report_xml }
    when "GET"
      { status: 200, headers: {}, body: alarm_ics }
    when "PUT"
      { status: 201, headers: {}, body: "" }
    when "DELETE"
      { status: 204, headers: {}, body: "" }
    else
      { status: 500, headers: {}, body: "" }
    end
  end

  def propfind_body(url)
    return principal_xml if url == "https://caldav.icloud.com/"
    return home_xml if url.include?("/principal/")

    @lists_xml || lists_xml
  end

  def principal_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <multistatus xmlns="DAV:">
        <response>
          <href>/</href>
          <propstat>
            <prop>
              <current-user-principal><href>/1/principal/</href></current-user-principal>
            </prop>
            <status>HTTP/1.1 200 OK</status>
          </propstat>
        </response>
      </multistatus>
    XML
  end

  def home_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <multistatus xmlns="DAV:">
        <response>
          <href>/1/principal/</href>
          <propstat>
            <prop>
              <calendar-home-set xmlns="urn:ietf:params:xml:ns:caldav">
                <href xmlns="DAV:">https://p01-caldav.icloud.com/1/calendars/</href>
              </calendar-home-set>
            </prop>
            <status>HTTP/1.1 200 OK</status>
          </propstat>
        </response>
      </multistatus>
    XML
  end

  def lists_xml(extra: "")
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <multistatus xmlns="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/">
        <response>
          <href>/1/calendars/</href>
          <propstat>
            <prop>
              <resourcetype><collection/></resourcetype>
              <displayname>home</displayname>
            </prop>
            <status>HTTP/1.1 200 OK</status>
          </propstat>
        </response>
        <response>
          <href>/1/calendars/reminders/</href>
          <propstat>
            <prop>
              <resourcetype><collection/><calendar xmlns="urn:ietf:params:xml:ns:caldav"/></resourcetype>
              <displayname>Reminders</displayname>
              <calendar-color xmlns="http://apple.com/ns/ical/">#FF9500FF</calendar-color>
              <supported-calendar-component-set xmlns="urn:ietf:params:xml:ns:caldav"><comp name="VTODO"/></supported-calendar-component-set>
            </prop>
            <status>HTTP/1.1 200 OK</status>
          </propstat>
        </response>
        <response>
          <href>/1/calendars/work/</href>
          <propstat>
            <prop>
              <resourcetype><collection/><calendar xmlns="urn:ietf:params:xml:ns:caldav"/></resourcetype>
              <displayname>Work</displayname>
              <supported-calendar-component-set xmlns="urn:ietf:params:xml:ns:caldav"><comp name="VEVENT"/></supported-calendar-component-set>
            </prop>
            <status>HTTP/1.1 200 OK</status>
          </propstat>
        </response>
        <response>
          <href>/1/calendars/inbox/</href>
          <propstat>
            <prop>
              <resourcetype><collection/><calendar xmlns="urn:ietf:params:xml:ns:caldav"/></resourcetype>
              <displayname>Inbox</displayname>
              <supported-calendar-component-set xmlns="urn:ietf:params:xml:ns:caldav"><comp name="VTODO"/></supported-calendar-component-set>
            </prop>
            <status>HTTP/1.1 200 OK</status>
          </propstat>
        </response>
        #{extra}
      </multistatus>
    XML
  end

  def errands_list_xml
    <<~XML
      <response>
        <href>/1/calendars/errands/</href>
        <propstat>
          <prop>
            <resourcetype><collection/><calendar xmlns="urn:ietf:params:xml:ns:caldav"/></resourcetype>
            <displayname>Errands</displayname>
            <supported-calendar-component-set xmlns="urn:ietf:params:xml:ns:caldav"><comp name="VTODO"/></supported-calendar-component-set>
          </prop>
          <status>HTTP/1.1 200 OK</status>
        </propstat>
      </response>
    XML
  end

  def empty_lists_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <multistatus xmlns="DAV:">
        <response>
          <href>/1/calendars/</href>
          <propstat>
            <prop><resourcetype><collection/></resourcetype><displayname>home</displayname></prop>
            <status>HTTP/1.1 200 OK</status>
          </propstat>
        </response>
      </multistatus>
    XML
  end

  def report_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <multistatus xmlns="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <response>
          <href>/1/calendars/reminders/milk.ics</href>
          <propstat><prop><calendar-data xmlns="urn:ietf:params:xml:ns:caldav">#{milk_ics}</calendar-data></prop><status>HTTP/1.1 200 OK</status></propstat>
        </response>
        <response>
          <href>/1/calendars/reminders/done.ics</href>
          <propstat><prop><calendar-data xmlns="urn:ietf:params:xml:ns:caldav">#{done_ics}</calendar-data></prop><status>HTTP/1.1 200 OK</status></propstat>
        </response>
        <response>
          <href>/1/calendars/reminders/nodue.ics</href>
          <propstat><prop><calendar-data xmlns="urn:ietf:params:xml:ns:caldav">#{nodue_ics}</calendar-data></prop><status>HTTP/1.1 200 OK</status></propstat>
        </response>
      </multistatus>
    XML
  end

  def milk_ics
    <<~ICS
      BEGIN:VCALENDAR
      BEGIN:VTODO
      UID:milk
      SUMMARY:Milk
      DESCRIPTION:oat
      URL:https://example.com/milk
      DUE:20261018T100000Z
      PRIORITY:1
      STATUS:NEEDS-ACTION
      END:VTODO
      END:VCALENDAR
    ICS
  end

  def done_ics
    <<~ICS
      BEGIN:VCALENDAR
      BEGIN:VTODO
      UID:done
      SUMMARY:Done
      DUE:20261001T100000Z
      COMPLETED:20261017T100000Z
      PRIORITY:9
      STATUS:COMPLETED
      END:VTODO
      END:VCALENDAR
    ICS
  end

  def nodue_ics
    <<~ICS
      BEGIN:VCALENDAR
      BEGIN:VTODO
      UID:nodue
      SUMMARY:No due
      PRIORITY:0
      STATUS:NEEDS-ACTION
      END:VTODO
      END:VCALENDAR
    ICS
  end

  def alarm_ics
    <<~ICS
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VTODO
      UID:milk
      SUMMARY:Milk
      DESCRIPTION:oat
      DUE:20261018T100000Z
      PRIORITY:1
      STATUS:NEEDS-ACTION
      BEGIN:VALARM
      ACTION:DISPLAY
      DESCRIPTION:alert
      TRIGGER:-PT15M
      END:VALARM
      END:VTODO
      END:VCALENDAR
    ICS
  end
end
