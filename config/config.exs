import Config

# This is the framework's own configuration, used only to develop and test it. An application
# that depends on the framework configures `config :vicander, repo: MyApp.Repo` itself.
if config_env() == :test, do: import_config("test.exs")
