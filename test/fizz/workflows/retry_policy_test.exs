defmodule Fizz.Workflows.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias Fizz.Workflows.{StepError, RetryPolicy}

  describe "validate!/1" do
    test "accepts a complete retry policy" do
      policy = %RetryPolicy{
        max_attempts: 3,
        backoff: :exponential,
        initial_delay_ms: 500,
        max_delay_ms: 30_000,
        retry_on: [:rate_limit, :network, :transient]
      }

      assert RetryPolicy.validate!(policy) == policy
    end

    test "rejects malformed retry policies" do
      assert_raise ArgumentError, ~r/invalid retry policy/, fn ->
        RetryPolicy.validate!(%RetryPolicy{max_attempts: 0})
      end

      assert_raise ArgumentError, ~r/invalid retry policy/, fn ->
        RetryPolicy.validate!(%RetryPolicy{backoff: :random})
      end

      assert_raise ArgumentError, ~r/invalid retry policy/, fn ->
        RetryPolicy.validate!(%RetryPolicy{retry_on: ["rate_limit"]})
      end
    end
  end

  describe "retryable?/3" do
    test "matches retryable step error categories while attempts remain" do
      policy = %RetryPolicy{max_attempts: 3, retry_on: [:rate_limit, :network]}
      rate_limited = %StepError{category: :rate_limit, retryable?: true}
      validation = %StepError{category: :validation, retryable?: false}

      assert RetryPolicy.retryable?(policy, rate_limited, 1)
      assert RetryPolicy.retryable?(policy, rate_limited, 2)
      refute RetryPolicy.retryable?(policy, rate_limited, 3)
      refute RetryPolicy.retryable?(policy, validation, 1)
    end
  end

  describe "next_delay_ms/3" do
    test "honors retry-after metadata before computed backoff" do
      policy = %RetryPolicy{
        max_attempts: 3,
        backoff: :exponential,
        initial_delay_ms: 250,
        max_delay_ms: 5_000
      }

      error = %StepError{category: :rate_limit, retryable?: true, retry_after_ms: 2_000}

      assert RetryPolicy.next_delay_ms(policy, error, 1) == 2_000
    end

    test "computes bounded exponential and linear backoff" do
      exponential = %RetryPolicy{
        max_attempts: 5,
        backoff: :exponential,
        initial_delay_ms: 250,
        max_delay_ms: 1_000
      }

      linear = %RetryPolicy{
        max_attempts: 5,
        backoff: :linear,
        initial_delay_ms: 250,
        max_delay_ms: 1_000
      }

      error = %StepError{category: :network, retryable?: true}

      assert RetryPolicy.next_delay_ms(exponential, error, 1) == 250
      assert RetryPolicy.next_delay_ms(exponential, error, 3) == 1_000
      assert RetryPolicy.next_delay_ms(linear, error, 3) == 750
    end
  end
end
