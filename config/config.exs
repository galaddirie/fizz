# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :fizz, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"*/3 * * * *", Fizz.Workspaces.Workers.ReconcileStaleJobsWorker},
       {"*/5 * * * *", Fizz.Workspaces.Workers.ConsoleReaperWorker},
       {"0 * * * *", Fizz.Workspaces.Workers.GCWorker},
       {"* * * * *", Fizz.Triggers.Workers.RegistrationSyncWorker}
     ]}
  ],
  queues: [default: 10, workspaces: 20, workspaces_maintenance: 5, triggers: 20],
  repo: Fizz.Repo

config :live_vue, ssr: true

config :phoenix_vite, PhoenixVite.Npm,
  assets: [args: [], cd: __DIR__],
  vite: [
    args: ~w(exec -- vite),
    cd: Path.expand("../assets", __DIR__),
    env: %{"MIX_BUILD_PATH" => Mix.Project.build_path()}
  ]

config :fizz, :scopes,
  user: [
    default: true,
    module: Fizz.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: Fizz.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :fizz,
  workspaces: [provider: "sprites"],
  ecto_repos: [Fizz.Repo],
  generators: [timestamp_type: :utc_datetime]

config :tesla, disable_deprecated_builder_warning: true

# Configure the endpoint
config :fizz, FizzWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FizzWeb.ErrorHTML, json: FizzWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Fizz.PubSub,
  live_view: [signing_salt: "Ws3nbsoN"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :fizz, Fizz.Mailer, adapter: Swoosh.Adapters.Local

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
