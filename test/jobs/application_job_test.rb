# frozen_string_literal: true

require "test_helper"

class ApplicationJobTest < ActiveJob::TestCase
  test "enqueue_safely returns nil on StatementTimeout and does not raise" do
    klass = Class.new(ApplicationJob) do
      def self.name = "BoomJob"

      def self.perform_later(*)
        raise ActiveRecord::StatementTimeout, "database is locked"
      end
    end

    assert_nil klass.enqueue_safely
  end

  test "enqueue_safely returns nil on SolidQueue enqueue errors" do
    skip unless defined?(SolidQueue::Job::EnqueueError)

    klass = Class.new(ApplicationJob) do
      def self.name = "BoomJob"

      def self.perform_later(*)
        raise SolidQueue::Job::EnqueueError, "database is locked"
      end
    end

    assert_nil klass.enqueue_safely
  end

  test "enqueue_safely still enqueues when the queue is healthy" do
    assert_enqueued_with(job: PurgeMcpActivityLogsJob) do
      PurgeMcpActivityLogsJob.enqueue_safely
    end
  end
end
