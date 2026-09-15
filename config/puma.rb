# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1. You can set it to `auto` to automatically start a worker
# for each available processor.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.

# ENV["FOO"] = "false" is truthy in Ruby — never use `if ENV["FLAG"]` for booleans.
def env_flag?(name, default: false)
  return Emcp.env_flag?(name, default: default) if defined?(Emcp) && Emcp.respond_to?(:env_flag?)

  val = ENV[name]
  return default if val.nil? || val.empty?

  %w[1 true yes on].include?(val.to_s.downcase)
end

threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", 5))
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Solid Queue belongs on emcp-worker (`SOLID_QUEUE_IN_PUMA=false`). The string
# "false" used to load this plugin and made web + worker both write SQLite.
plugin :solid_queue if env_flag?("SOLID_QUEUE_IN_PUMA")

# WhatsApp's Go sidecar is a child of this process (127.0.0.1). Keep it up after
# deploys and crashes; Solid Queue on the worker container cannot reach it.
on_booted do
  require Rails.root.join("servers/whatsapp/keepalive")
  Emcp::Servers::Whatsapp::Keepalive.start_in_puma
  Emcp::Servers::Whatsapp::Keepalive.supervise
end

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"].to_s != ""
