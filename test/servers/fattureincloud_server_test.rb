# frozen_string_literal: true

require "test_helper"

class FattureInCloudServerTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:calls) do
    def get(path, query: {})
      calls << [ path, query.compact ]
      { status: 200, body: { data: [] } }
    end
  end

  setup do
    @server = mcp_server_for("fattureincloud")
    @client = FakeClient.new([])
    @server.instance_variable_set(:@client, @client)
    ENV["FATTUREINCLOUD_COMPANY_ID"] = "42"
  end

  teardown { ENV.delete("FATTUREINCLOUD_COMPANY_ID") }

  test "catalog exposes cost and cashbook reads without write gate" do
    %w[
      fattureincloud_received_documents fattureincloud_received_document
      fattureincloud_cashbook fattureincloud_cashbook_entry
    ].each do |name|
      assert_not tool(name)[:write], "#{name} must be read-only"
    end

    refute_includes @server.tool_catalog.map { |t| t[:name] }, "fattureincloud_received_document_create"
  end

  test "cashbook requires a date range" do
    assert_equal %w[date_from date_to], tool("fattureincloud_cashbook")[:input_schema][:required]
  end

  test "received documents default to expense and forward filters" do
    @server.call_tool("fattureincloud_received_documents", { q: "date >= '2026-01-01'", per_page: 25 })

    path, query = @client.calls.last
    assert_equal "/c/42/received_documents", path
    assert_equal({ type: "expense", q: "date >= '2026-01-01'", per_page: 25 }, query)
  end

  test "cashbook forwards the date range" do
    @server.call_tool("fattureincloud_cashbook", { date_from: "2026-01-01", date_to: "2026-06-30" })

    path, query = @client.calls.last
    assert_equal "/c/42/cashbook", path
    assert_equal({ date_from: "2026-01-01", date_to: "2026-06-30" }, query)
  end

  test "get one received document uses the id in the path" do
    @server.call_tool("fattureincloud_received_document", { id: "7" })

    assert_equal "/c/42/received_documents/7", @client.calls.last.first
  end

  private

  def tool(name)
    @server.tool_catalog.find { |t| t[:name] == name }.tap { |t| assert t, "missing tool #{name}" }
  end
end
