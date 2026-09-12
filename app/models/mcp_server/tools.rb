# frozen_string_literal: true

require "shellwords"

module McpServer::Tools
  extend ActiveSupport::Concern

  MODERN_PROTOCOL_VERSION = "2026-07-28"
  PROTOCOL_VERSION_META_KEY = "io.modelcontextprotocol/protocolVersion"
  SERVER_INFO_META_KEY = "io.modelcontextprotocol/serverInfo"
  CACHEABLE_RESULT_KEYS = %w[tools prompts resources resourceTemplates contents].freeze

  def tool_catalog
    configure_once!
    tools.map do |tool|
      {
        name: tool.name,
        description: tool.description,
        input_schema: tool.input_schema,
        output_schema: tool.output_schema,
        write: tool.write,
        enabled: !tool.write || allow_write_methods?,
      }
    end
  end

  def call_tool(name, arguments = {})
    configure_once!
    definition = tools.find { |candidate| candidate.name == name }
    raise KeyError, "unknown tool: #{name}" unless definition
    if definition.write && !allow_write_methods?
      error = SecurityError.new("write method disabled")
      log_tool_activity(definition.name, arguments, result: nil, error: error)
      raise error
    end

    invoke_logged_tool(definition, arguments)
  end

  def mcp_protocol_server
    configure_once!
    @mcp_protocol_server ||= build_mcp_protocol_server
  end

  # ChatGPT web (openai-mcp) speaks MCP 2026-07-28: it probes `server/discover`
  # and then lists tools without the legacy `initialize` handshake. The mcp 0.25
  # gem answers discover with only 2025 versions, so ChatGPT treats the 200 as a
  # failed connector refresh. Shape the modern result here until we can bump the gem.
  def handle_mcp_json(body)
    parsed = JSON.parse(body)
    return mcp_protocol_server.handle_json(body) unless parsed.is_a?(Hash)

    if parsed["method"] == "server/discover"
      return jsonrpc_result(parsed["id"], modern_discover_result)
    end

    response = mcp_protocol_server.handle_json(body)
    return response unless response.is_a?(String) && modern_mcp_request?(parsed)

    stamp_modern_result(response)
  rescue JSON::ParserError
    mcp_protocol_server.handle_json(body)
  end

  protected

  def define_tool(name:, description:, properties: {}, required: [], write: false, output_schema: nil, &handler)
    schema = {
      type: "object",
      properties: properties,
      additionalProperties: false,
    }
    schema[:required] = required if required.present?

    tools << Emcp::ToolDefinition.new(
      name: name,
      description: description,
      input_schema: schema,
      output_schema: output_schema || default_output_schema,
      write: write,
      handler: handler,
    )
  end

  def define_resource(uri:, name:, description:, mime_type: "text/plain", &handler)
    resources << Emcp::ResourceDefinition.new(
      uri: uri,
      name: name,
      description: description,
      mime_type: mime_type,
      handler: handler,
    )
  end

  def text_response(text)
    structured_tool_result(text.to_s, data: nil)
  end

  def api_response(result = nil)
    payload = block_given? ? yield : result
    structured_tool_result(JSON.pretty_generate(payload), data: payload)
  rescue StandardError => e
    text_response("ERROR: #{e.message}")
  end

  def cli_response(client, args)
    Current.mcp_command = [client.bin, *Array(args)].shelljoin
    text_response(client.run(args))
  rescue Emcp::CliError => e
    text_response("ERROR: #{e.message}")
  end

  def object_prop(description)
    { type: "object", description: description, additionalProperties: true }
  end

  def compact_hash(values)
    values.reject { |_, value| value.nil? || value == "" }
  end

  def stringify_keys(values)
    values.to_h.transform_keys(&:to_s)
  end

  def string_prop(description) = { type: "string", description: description }
  def integer_prop(description) = { type: "integer", description: description }
  def boolean_prop(description) = { type: "boolean", description: description }
  def array_prop(description) = { type: "array", items: { type: "string" }, description: description }

  private

  def tools
    @tools ||= []
  end

  def resources
    @resources ||= []
  end

  def configure_once!
    return if @configured

    configure_tools
    @configured = true
  end

  def invoke_logged_tool(definition, arguments)
    filtered = filter_tool_arguments(definition, arguments)
    Current.mcp_command = nil
    error = nil
    result = begin
      instance_exec(**filtered, &definition.handler)
    rescue StandardError => e
      error = e
      nil
    end
    log_tool_activity(definition.name, filtered, result: result, error: error)
    raise error if error

    result
  end

  def log_tool_activity(tool, arguments, result:, error:)
    McpActivityLog.record(
      server: code,
      tool: tool,
      status: tool_activity_status(result, error),
      command: Current.mcp_command.presence || McpActivityLog.command_from_arguments(tool, arguments),
      ip: Current.remote_ip,
      user: Current.user&.email.presence || Current.mcp_actor,
    )
  end

  def tool_activity_status(result, error)
    return "ko" if error

    text = tool_activity_text(result)
    return "ko" if text.to_s.start_with?("ERROR:")

    "ok"
  end

  def tool_activity_text(result)
    return result.to_s unless result.respond_to?(:content)

    first = Array(result.content).first
    case first
    when Hash then first[:text] || first["text"]
    else first.to_s
    end
  end

  def filter_tool_arguments(definition, arguments)
    allowed = definition.input_schema.fetch(:properties, {}).keys.map(&:to_sym)
    arguments.to_h.transform_keys(&:to_sym).select { |key, _| allowed.include?(key) }
  end

  def default_output_schema
    {
      type: "object",
      properties: {
        text: { type: "string", description: "Human-readable tool output." },
        data: { description: "Structured JSON payload when the tool returns data." },
      },
      required: ["text"],
      additionalProperties: false,
    }
  end

  def structured_tool_result(text, data:)
    MCP::Tool::Response.new(
      [{ type: "text", text: text }],
      structured_content: { "text" => text, "data" => data },
    )
  end

  def modern_mcp_request?(parsed)
    parsed.dig("params", "_meta", PROTOCOL_VERSION_META_KEY) == MODERN_PROTOCOL_VERSION
  end

  def modern_discover_result
    configure_once!
    capabilities = { "tools" => {} }
    capabilities["resources"] = {} if resources.any?

    {
      "resultType" => "complete",
      "supportedVersions" => [MODERN_PROTOCOL_VERSION],
      "capabilities" => capabilities,
      "instructions" => instructions,
      "ttlMs" => 0,
      "cacheScope" => "private",
      "_meta" => {
        SERVER_INFO_META_KEY => { "name" => code, "version" => version },
      },
    }
  end

  def jsonrpc_result(id, result)
    JSON.generate("jsonrpc" => "2.0", "id" => id, "result" => result)
  end

  def stamp_modern_result(json_string)
    payload = JSON.parse(json_string)
    result = payload["result"]
    return json_string unless result.is_a?(Hash)

    result["resultType"] ||= "complete"
    if CACHEABLE_RESULT_KEYS.any? { |key| result.key?(key) }
      result["ttlMs"] ||= 0
      result["cacheScope"] ||= "private"
    end
    payload["result"] = result
    JSON.generate(payload)
  rescue JSON::ParserError
    json_string
  end

  # ChatGPT web requires these hints on every tool; Claude is lenient without them.
  def protocol_tool_annotations(definition)
    if definition.write
      {
        read_only_hint: false,
        destructive_hint: false,
        idempotent_hint: false,
        open_world_hint: true,
      }
    else
      {
        read_only_hint: true,
        destructive_hint: false,
        idempotent_hint: true,
        open_world_hint: true,
      }
    end
  end

  def build_mcp_protocol_server
    integration = self
    server = MCP::Server.new(
      name: code,
      version: version,
      instructions: instructions,
      resources: resources.map do |resource|
        MCP::Resource.new(
          uri: resource.uri,
          name: resource.name,
          description: resource.description,
          mime_type: resource.mime_type,
        )
      end,
    )
    unless resources.empty?
      server.resources_read_handler do |params|
        uri = params[:uri]
        resource = resources.find { |candidate| candidate.uri == uri }
        raise KeyError, "unknown resource: #{uri}" unless resource

        [{
          uri: resource.uri,
          mimeType: resource.mime_type,
          text: resource.handler.call,
        }]
      end
    end
    tools.each do |definition|
      server.define_tool(
        name: definition.name,
        title: definition.name.tr("_", " "),
        description: definition.description,
        input_schema: definition.input_schema,
        output_schema: definition.output_schema,
        annotations: protocol_tool_annotations(definition),
      ) do |**arguments|
        if definition.write && !integration.allow_write_methods?
          error = SecurityError.new(
            "write method disabled. Set #{integration.code.upcase}_ALLOW_WRITE=true or mcp_server.allow_write.",
          )
          integration.send(:log_tool_activity, definition.name, arguments, result: nil, error: error)
          integration.send(:text_response, "ERROR: #{error.message}")
        else
          integration.send(:invoke_logged_tool, definition, arguments)
        end
      rescue StandardError => e
        integration.send(:text_response, "ERROR: #{e.message}")
      end
    end
    server
  end
end
