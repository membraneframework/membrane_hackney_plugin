import Config

config :mockery, history: true

if config_env() == :test do
  import_config "test.exs"
end
