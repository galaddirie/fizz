run_external_api_tests? = System.get_env("RUN_EXTERNAL_API_TESTS") == "1"
exclude_tags = if run_external_api_tests?, do: [], else: [:external_api]

ExUnit.start(exclude: exclude_tags)
Ecto.Adapters.SQL.Sandbox.mode(Fizz.Repo, :manual)
