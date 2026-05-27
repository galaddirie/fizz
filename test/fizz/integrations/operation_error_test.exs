defmodule Fizz.Integrations.OperationErrorTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.OperationError

  describe "http/2" do
    test "normalizes rate-limit responses with retry metadata" do
      error =
        OperationError.http(%{
          status: 429,
          headers: [{"retry-after", "7"}],
          body: %{"error" => %{"message" => "slow down"}}
        })

      assert %OperationError{} = error
      assert error.code == :rate_limited
      assert error.category == :rate_limit
      assert error.status == 429
      assert error.retry_after_ms == 7_000
      assert error.retryable?
      assert error.message == "slow down"
    end

    test "normalizes transient provider responses" do
      error =
        OperationError.http(%{
          status: 503,
          headers: [],
          body: %{"error" => %{"message" => "temporarily unavailable"}}
        })

      assert error.code == :provider_unavailable
      assert error.category == :transient
      assert error.status == 503
      assert error.retryable?
    end

    test "normalizes auth and permission responses as non-retryable" do
      unauthorized = OperationError.http(%{status: 401, headers: [], body: %{}})
      forbidden = OperationError.http(%{status: 403, headers: [], body: %{}})

      assert unauthorized.code == :unauthorized
      assert unauthorized.category == :auth
      refute unauthorized.retryable?

      assert forbidden.code == :forbidden
      assert forbidden.category == :permission
      refute forbidden.retryable?
    end
  end

  describe "normalize/2" do
    test "keeps existing operation errors intact" do
      error = OperationError.new(code: :custom, category: :validation, message: "bad input")

      assert OperationError.normalize(error) == error
    end

    test "turns credential and validation atoms into operation errors" do
      credential_error = OperationError.normalize(:credential_ref_required)
      invalid_row_error = OperationError.normalize(:invalid_row_values)

      assert credential_error.code == :credential_ref_required
      assert credential_error.category == :credential
      assert credential_error.message =~ "credential"

      assert invalid_row_error.code == :invalid_row_values
      assert invalid_row_error.category == :validation
      refute invalid_row_error.retryable?
    end

    test "normalizes missing param and context tuples" do
      missing_param = OperationError.normalize({:missing_param, "spreadsheet_id"})
      missing_context = OperationError.normalize({:missing_context, :project_id})

      assert missing_param.code == :missing_param
      assert missing_param.category == :validation
      assert missing_param.details == %{param: "spreadsheet_id"}

      assert missing_context.code == :missing_context
      assert missing_context.category == :validation
      assert missing_context.details == %{context_key: :project_id}
    end
  end
end
