# frozen_string_literal: true

# Truncate SQLite WAL files that otherwise grow ~10x the db on slow NAS volumes.
class SqliteCheckpointJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: -> { "sqlite_checkpoint" }, duration: 1.hour

  def perform
    klasses = [
      ActiveRecord::Base,
      (SolidQueue::Record if defined?(SolidQueue::Record)),
      (SolidCache::Record if defined?(SolidCache::Record)),
      (SolidCable::Record if defined?(SolidCable::Record))
    ].compact

    klasses.each do |klass|
      klass.connection_pool.with_connection do |conn|
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
      end
    rescue StandardError => e
      Rails.logger.warn("[checkpoint] #{klass}: #{e.message}")
    end
  end
end
