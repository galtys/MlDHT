# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
use Mix.Config

# This configuration is loaded before any dependency and is restricted
# to this project. If another project depends on this project, this
# file won't be loaded nor affect the parent project. For this reason,
# if you want to provide default values for your application for third-
# party users, it should be done in your mix.exs file.

# Sample configuration:
#
#     config :logger, :console,
#       level: :info,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]

# It is also possible to import configuration files, relative to this
# directory. For example, you can emulate configuration per environment
# by uncommenting the line below and defining dev.exs, test.exs and such.
# Configuration from the imported file will override the ones defined
# here (which is why it is important to import them last).
#
#     import_config "#{Mix.env}.exs"

config :logger, :console,
  level: :debug,
  format: "$date $time [$level] $metadata$message\n",
  metadata: [:user_id]

config :dht_server,
bootstrap_nodes: [
  {"32f54e697351ff4aec29cdbaabf2fbe3467cc267", "router.bittorrent.com",  6881},
  {"ebff36697351ff4aec29cdbaabf2fbe3467cc267", "router.utorrent.com",    6881},
  {"9f08e1074f1679137561bafe2cf62a73a8afadc7", "dht.transmissionbt.com", 6881},
]
