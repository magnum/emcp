# frozen_string_literal: true

require "test_helper"

class WebhookJobTest < ActiveJob::TestCase
  setup do
    @server = mcp_server_for("whatsapp")
    @hook = @server.whatsapp_hooks.create!(
      url: "https://example.com/hook",
      secret: "supersecret",
    )
  end

  test "a 200 completes the webhook" do
    record = enqueue_webhook
    with_post(http(200, "ok")) { WebhookJob.perform_now(record.id) }
    assert record.reload.completed?
    assert_equal 200, record.response_code
  end

  test "a 4xx is final" do
    record = enqueue_webhook
    assert_no_enqueued_jobs only: WebhookJob do
      with_post(http(422, "no")) { WebhookJob.perform_now(record.id) }
    end
    assert record.reload.error?
    assert_equal 422, record.response_code
  end

  test "a 5xx is recorded and scheduled again" do
    record = enqueue_webhook
    assert_enqueued_jobs 1, only: WebhookJob do
      with_post(http(503, "down")) { WebhookJob.perform_now(record.id) }
    end
    assert record.reload.error?
    assert_equal 503, record.response_code
  end

  test "a network error is scheduled again without a status" do
    record = enqueue_webhook
    assert_enqueued_jobs 1, only: WebhookJob do
      with_post(-> { raise SocketError, "down" }) { WebhookJob.perform_now(record.id) }
    end
    assert record.reload.error?
    assert_nil record.response_code
  end

  private

  def enqueue_webhook
    record = @hook.webhook!(:post, @hook.url, body: { event: "webhook.test" }.to_json, headers: { "Content-Type" => "application/json" }, async: true)
    clear_enqueued_jobs
    record
  end

  def with_post(response)
    singleton = HTTParty.singleton_class
    singleton.alias_method(:post_without_webhook_test, :post)
    HTTParty.define_singleton_method(:post) do |*, **|
      response.respond_to?(:call) ? response.call : response
    end
    yield
  ensure
    singleton.alias_method(:post, :post_without_webhook_test)
  end

  def http(code, body)
    response = Object.new
    response.define_singleton_method(:code) { code }
    response.define_singleton_method(:body) { body }
    response.define_singleton_method(:headers) { {} }
    response
  end
end
