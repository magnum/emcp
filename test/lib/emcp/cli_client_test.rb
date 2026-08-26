# frozen_string_literal: true

require "test_helper"

class Emcp::CliClientTest < ActiveSupport::TestCase
  test "does not pass jemalloc LD_PRELOAD to CLI children" do
    previous = ENV["LD_PRELOAD"]
    ENV["LD_PRELOAD"] = "/usr/local/lib/libjemalloc.so"
    output = Emcp::CliClient.new(bin: "sh", timeout: 5).run(["-c", 'printf %s "${LD_PRELOAD-}"'])
    assert_equal "", output
  ensure
    if previous
      ENV["LD_PRELOAD"] = previous
    else
      ENV.delete("LD_PRELOAD")
    end
  end
end
