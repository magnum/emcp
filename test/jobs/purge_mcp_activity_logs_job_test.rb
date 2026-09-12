# frozen_string_literal: true

require "test_helper"

class PurgeMcpActivityLogsJobTest < ActiveJob::TestCase
  setup do
    McpActivityLog.reset!
    FileUtils.rm_rf(McpActivityLog.directory)
  end

  teardown do
    McpActivityLog.reset!
    FileUtils.rm_rf(McpActivityLog.directory)
  end

  test "performs purge" do
    dir = McpActivityLog.directory
    FileUtils.mkdir_p(dir)
    stale = dir.join("hey.log.20180101")
    File.write(stale, "stale\n")

    PurgeMcpActivityLogsJob.perform_now

    refute_path_exists stale
  end
end
