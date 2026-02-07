defmodule Fizz.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query

  alias Fizz.Accounts.UserToken

  @rand_size 32
  @session_validity_in_days 14

  schema "users_tokens" do
    field :token, :binary
    field :authenticated_at, :utc_datetime
    belongs_to :user, Fizz.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a session token and persistence struct.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = user.authenticated_at || DateTime.utc_now(:second)

    {token, %UserToken{token: token, user_id: user.id, authenticated_at: dt}}
  end

  @doc """
  Checks if the token is valid and returns its lookup query.
  """
  def verify_session_token_query(token) do
    query =
      from token in by_token_query(token),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}

    {:ok, query}
  end

  defp by_token_query(token) do
    from UserToken, where: [token: ^token]
  end
end
