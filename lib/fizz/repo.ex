defmodule Fizz.Repo do
  use Ecto.Repo,
    otp_app: :fizz,
    adapter: Ecto.Adapters.Postgres
end
