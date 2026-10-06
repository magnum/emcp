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
      scope = SolidQueue::Job.where(class_name: name, finished_at: nil)
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
    failures = context.context_memberships.includes(:mcp_server).filter_map do |membership|
      server = membership.mcp_server
      failure = server.record_service_probe!
      next unless failure

      failure.merge(paused: !membership.active?)
    end
    context.record_service_probe!
    key = self.class.signature_key(context.id)
    if failures.empty?
      Rails.cache.delete(key)
      return
    end

    signature = failures.map { |row| row[:id] }.sort.join(",")
    return if Rails.cache.read(key) == signature

    ContextStatusMailer.unauthenticated(context, failures).deliver_now
    Rails.cache.write(key, signature, expires_in: 7.days)
  rescue StandardError => e
    Rails.logger.error("[check_status] context #{context.id}: #{e.class}: #{e.message}")
  end
end
