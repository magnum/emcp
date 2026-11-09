# frozen_string_literal: true

# One chain per context. The first run starts immediately; each finish
# enqueues the next run after EMCP_STATUS_INTERVAL seconds (default 1800).
class CheckStatusJob < ApplicationJob
  queue_as :default

  def perform(context_id)
    context = McpServer.contexts.find_by(id: context_id)
    return unless context

    notify_unauthenticated(context)
  ensure
    self.class.schedule_next(context_id, except_job_id: job_id)
  end

  def self.ensure_running!(context)
    return unless context&.context?
    return if pending?(context.id)

    enqueue_safely(context.id)
  end

  def self.sync_all!
    McpServer.contexts.find_each { |context| ensure_running!(context) }
  end

  def self.schedule_next(context_id, except_job_id: nil)
    return unless McpServer.contexts.exists?(id: context_id)
    return if pending?(context_id, except_job_id: except_job_id)

    enqueue_safely(context_id, wait: Emcp.status_interval)
  end

  def self.clear_signature!(context_id)
    Rails.cache.delete(signature_key(context_id))
  end

  def self.pending?(context_id, except_job_id: nil)
    if queue_adapter.is_a?(ActiveJob::QueueAdapters::TestAdapter)
      queue_adapter.enqueued_jobs.any? do |job|
        job[:job] == self && argument_context_id(job[:args]) == context_id
      end
    elsif defined?(SolidQueue::Job)
      # A failed row stays unfinished. Counting it as pending freezes the
      # chain: ensure_running! never enqueues a replacement.
      scope = SolidQueue::Job.where(class_name: name, finished_at: nil).where.missing(:failed_execution)
      scope = scope.where.not(active_job_id: except_job_id) if except_job_id.present?
      scope.any? { |record| argument_context_id(record.arguments) == context_id }
    else
      false
    end
  end

  def self.signature_key(context_id)
    "emcp/context_status/#{context_id}"
  end

  def self.argument_context_id(arguments)
    raw = arguments.is_a?(Hash) ? (arguments["arguments"] || arguments[:arguments]) : arguments
    value = Array(raw).first
    value = value["context_id"] || value[:context_id] if value.is_a?(Hash)
    Integer(value)
  rescue ArgumentError, TypeError
    nil
  end

  private

  def notify_unauthenticated(context)
    rows = context.context_memberships.includes(:mcp_server).map { |membership| probe_membership(membership) }
    context.record_service_probe!
    failures = rows.reject { |row| row[:connected] }
    healthy = rows.select { |row| row[:connected] }
    key = self.class.signature_key(context.id)
    if failures.empty?
      Rails.cache.delete(key)
      return
    end

    signature = failures.map { |row| row[:id] }.sort.join(",")
    return if Rails.cache.read(key) == signature

    ContextStatusMailer.unauthenticated(context, failures, healthy).deliver_now
    Rails.cache.write(key, signature, expires_in: 7.days)
  rescue StandardError => e
    Rails.logger.error("[check_status] context #{context.id}: #{e.class}: #{e.message}")
  end

  def probe_membership(membership)
    server = membership.mcp_server
    failure = server.record_service_probe!
    {
      id: server.id,
      name: server.name,
      instance: server.activity_log_code,
      paused: !membership.active?,
      error: failure && failure[:error],
      connected: failure.nil?,
    }
  end
end
