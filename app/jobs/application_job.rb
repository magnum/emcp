# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  ENQUEUE_ERRORS = [
    ActiveRecord::StatementTimeout,
    ActiveRecord::LockWaitTimeout,
    (SolidQueue::Job::EnqueueError if defined?(SolidQueue::Job::EnqueueError))
  ].compact.freeze

  # SQLite on NAS storage can refuse writes under I/O load. A missed maintenance
  # job must not turn an HTTP request into a 502.
  def self.enqueue_safely(*args, wait: nil, **kwargs)
    (wait ? set(wait: wait) : self).perform_later(*args, **kwargs)
  rescue *ENQUEUE_ERRORS => e
    Rails.logger.warn("[enqueue] skipped #{name}: #{e.class}: #{e.message}")
    nil
  end
end
