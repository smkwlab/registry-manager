import Config

# Logger configuration for escript
config :logger,
  level: :warning,
  compile_time_purge_matching: [
    [level_lower_than: :warning]
  ]
