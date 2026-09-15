# frozen_string_literal: true

require "test_helper"

class SqliteCheckpointJobTest < ActiveJob::TestCase
  test "runs wal_checkpoint against the primary connection" do
    assert_nothing_raised { SqliteCheckpointJob.perform_now }
  end
end
