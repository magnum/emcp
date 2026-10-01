ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    def provision_mcp_servers!(user = users(:one))
      McpServerType.discover!
      McpServer.provision_defaults_for!(user)
    end

    def mcp_server_for(code, user: users(:one))
      if code.to_s == "context"
        existing = user.mcp_servers.joins(:mcp_server_type).find_by(mcp_server_types: { code: "context" })
        return existing || create_context!(user: user)
      end

      provision_mcp_servers!(user) unless user.mcp_servers.joins(:mcp_server_type).exists?(mcp_server_types: { code: code.to_s })
      McpServer.for_user_and_code!(user, code)
    end

    def create_context!(user: users(:one), name: "House", description: "home", servers: [])
      McpServerType.discover!
      type = McpServerType.fetch!("context")
      record = user.mcp_servers.create!(
        mcp_server_type: type,
        name: name,
        description: description,
      )
      context = McpServer.find(record.id)
      Array(servers).each { |server| context.context_memberships.create!(mcp_server: server) }
      context.reload
    end
  end
end
