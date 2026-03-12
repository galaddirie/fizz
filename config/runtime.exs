import Config
import Nvir

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

dotenv!([".env", ".env.#{config_env()}"])

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/fizz start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :fizz, FizzWeb.Endpoint, server: true
end

config :fizz, FizzWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :fizz,
  workos_sync_enabled: System.get_env("WORKOS_SYNC_ENABLED") in ~w(1 true TRUE),
  workos_authkit_provider: System.get_env("WORKOS_AUTHKIT_PROVIDER", "authkit"),
  workos_authkit_redirect_uri: System.get_env("WORKOS_AUTHKIT_REDIRECT_URI"),
  workos_authkit_logout_return_uri: System.get_env("WORKOS_AUTHKIT_LOGOUT_RETURN_URI"),
  workos_webhook_secret: System.get_env("WORKOS_WEBHOOK_SECRET"),
  workos_role_slug_map: %{
    owner: System.get_env("WORKOS_ROLE_SLUG_OWNER", "owner"),
    admin: System.get_env("WORKOS_ROLE_SLUG_ADMIN", "admin"),
    member: System.get_env("WORKOS_ROLE_SLUG_MEMBER", "member")
  }

config :fizz, :workspaces, provider: System.get_env("WORKSPACE_PROVIDER", "sprites")

config :fizz, Fizz.Workspaces.Providers.Sprites,
  api_key: System.get_env("WORKSPACE_SPRITES_API_KEY"),
  api_base_url: System.get_env("WORKSPACE_SPRITES_API_BASE_URL", "https://api.sprites.dev"),
  default_region: System.get_env("WORKSPACE_SPRITES_DEFAULT_REGION"),
  log_retention_days:
    String.to_integer(System.get_env("WORKSPACE_SPRITES_LOG_RETENTION_DAYS", "14")),
  checkpoint_retention_days:
    String.to_integer(System.get_env("WORKSPACE_SPRITES_CHECKPOINT_RETENTION_DAYS", "14")),
  service_log_tail_lines:
    String.to_integer(System.get_env("WORKSPACE_SPRITES_SERVICE_LOG_TAIL_LINES", "200")),
  exec_timeout_ms_default:
    String.to_integer(System.get_env("WORKSPACE_SPRITES_EXEC_TIMEOUT_MS_DEFAULT", "30000"))

if api_key = System.get_env("WORKOS_API_KEY") do
  config :workos, WorkOS.Client,
    api_key: api_key,
    client_id: System.get_env("WORKOS_CLIENT_ID"),
    client: Fizz.Accounts.WorkOS.ReqClient
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :fizz, Fizz.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :fizz, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :fizz, FizzWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base,
    cache_static_manifest_latest: PhoenixVite.cache_static_manifest_latest(:fizz)

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :fizz, FizzWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :fizz, FizzWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :fizz, Fizz.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
