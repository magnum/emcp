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
      provision_mcp_servers!(user) unless user.mcp_servers.joins(:mcp_server_type).exists?(mcp_server_types: { code: code.to_s })
      McpServer.for_user_and_code!(user, code)
    end
  end
end
