# frozen_string_literal: true

require "test_helper"
require "stringio"

class TessieServerTest < ActiveSupport::TestCase
  VIN = "5YJ3E1EA1KF000001"

  setup do
    @server = mcp_server_for("tessie")
    @server.update!(allow_write: true)
    @transport = ScriptedTransport.new
    @client = Emcp::Servers::Tessie::Client.new(token: "super-secret-token", transport: @transport)
    @client.define_singleton_method(:pause) { |_seconds| }
    @server.instance_variable_set(:@client, @client)
    ENV["TESSIE_DEFAULT_VIN"] = VIN
  end

  teardown do
    ENV.delete("TESSIE_DEFAULT_VIN")
  end

  test "list_vehicles returns vin, name, and state" do
    @transport.respond("/vehicles", {
      "results" => [
        { "vin" => VIN, "last_state" => { "display_name" => "Red", "state" => "asleep" } },
      ],
    })

    data = tool_data("tessie_list_vehicles")

    assert_equal [ { "vin" => VIN, "name" => "Red", "state" => "asleep" } ], data
    assert_equal [ :get, "/vehicles" ], @transport.calls.first.first(2)
  end

  test "get_state returns a compact summary and does not ask tessie to wake the car" do
    @transport.respond("/#{VIN}/state", sample_state)

    data = tool_data("tessie_get_state")

    assert_equal VIN, data["vin"]
    assert_equal 72.0, data["battery_percent"]
    assert_equal 321.9, data["range_km"]
    assert_equal true, data["charging"]
    assert_equal 80.0, data["charge_limit_percent"]
    assert_equal true, data["climate_on"]
    assert_equal 21.5, data["inside_c"]
    assert_equal 9.0, data["outside_c"]
    assert_equal true, data["locked"]
    assert_equal true, data["windows_open"]
    assert_equal false, data["frunk_open"]
    assert_equal true, data["trunk_open"]
    assert_equal true, data["sentry"]
    assert_equal "Home", data.dig("navigation", "destination")
    assert_equal 12.9, data.dig("navigation", "km_to_arrival")
    query = @transport.calls.last[2]
    assert_equal "true", query["use_cache"]
  end

  test "write tools stay disabled until allow_write is on" do
    @server.update!(allow_write: false)

    error = assert_raises(SecurityError) { @server.call_tool("tessie_lock", {}) }
    assert_match(/write method disabled/, error.message)
    assert_empty @transport.calls
  end

  test "lock wakes an asleep vehicle and waits for completion" do
    @transport.respond("/#{VIN}/status", { "status" => "asleep" })
    @transport.respond("/#{VIN}/wake", { "result" => true })
    @transport.respond("/#{VIN}/command/lock", { "result" => true })

    data = tool_data("tessie_lock")

    assert_equal true, data["ok"]
    assert_equal "lock", data["command"]
    assert_equal VIN, data["vin"]
    assert_equal "lock completed.", data["message"]
    methods = @transport.calls.map { |method, path, _query, _timeout| [ method, path ] }
    assert_equal [
      [ :get, "/#{VIN}/status" ],
      [ :post, "/#{VIN}/wake" ],
      [ :post, "/#{VIN}/command/lock" ],
    ], methods
    assert_equal "true", @transport.calls.last[2]["wait_for_completion"]
    assert_equal "3", @transport.calls.last[2]["max_attempts"]
  end

  test "a rejected token is not retried or written to the log" do
    @transport.sequence << [ 401, { "error" => "unauthorized" }, {} ]
    buffer = StringIO.new
    previous = Rails.logger
    Rails.logger = Logger.new(buffer)

    error = assert_raises(Emcp::Servers::Tessie::Client::Error) { @client.vehicles }
    assert_match(/401/, error.message)
    assert_equal 1, @transport.calls.size
    refute_includes buffer.string, "super-secret-token"
    assert_match(%r{GET /vehicles 401}, buffer.string)
  ensure
    Rails.logger = previous
  end

  test "rate limits are retried" do
    @transport.sequence << [ 429, { "error" => "slow down" }, { "retry-after" => "0" } ]
    @transport.sequence << [ 200, { "results" => [] }, {} ]

    assert_equal({ "results" => [] }, @client.vehicles)
    assert_equal 2, @transport.calls.size
  end

  private

  def tool_data(name, arguments = {})
    result = @server.call_tool(name, arguments)
    result.structured_content["data"]
  end

  def sample_state
    {
      "vin" => VIN,
      "display_name" => "Red",
      "state" => "online",
      "charge_state" => {
        "battery_level" => 72,
        "battery_range" => 200,
        "charging_state" => "Charging",
        "charge_limit_soc" => 80,
      },
      "climate_state" => { "is_climate_on" => true, "inside_temp" => 21.5, "outside_temp" => 9 },
      "vehicle_state" => {
        "locked" => true,
        "fd_window" => 4,
        "fp_window" => 0,
        "rd_window" => 0,
        "rp_window" => 0,
        "ft" => 0,
        "rt" => 1,
        "sentry_mode" => true,
      },
      "drive_state" => {
        "latitude" => 45.46,
        "longitude" => 9.19,
        "active_route_destination" => "Home",
        "active_route_minutes_to_arrival" => 18,
        "active_route_miles_to_arrival" => 8,
      },
    }
  end

  class ScriptedTransport
    attr_reader :calls, :sequence

    def initialize
      @calls = []
      @routes = {}
      @sequence = []
    end

    def respond(path, body)
      @routes[path] = body
    end

    def call(method, path, query, _timeout)
      @calls << [ method, path, query ]
      if @sequence.any?
        status, body, headers = @sequence.shift
        return [ status, JSON.generate(body), headers ]
      end

      [ 200, JSON.generate(@routes.fetch(path)), {} ]
    end
  end
end
