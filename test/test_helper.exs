# Safety check - ensure we're in test environment
# Note: Mix automatically sets MIX_ENV=test when running `mix test`
current_env = System.get_env("MIX_ENV") || Mix.env() |> to_string()

if current_env != "test" do
  IO.puts("")
  IO.puts("⚠️  WARNING: Tests must be run in test environment")
  IO.puts("⚠️  Current environment: #{inspect(current_env)}")
  IO.puts("⚠️  Use: mix test (will auto-set MIX_ENV=test)")
  IO.puts("")
  System.halt(1)
end

# Set application environment for test context
Application.put_env(:registry_manager, :env, :test)

# Setup global mock for all tests
RegistryManager.Test.GitHubAPIMock.setup_mock()
RegistryManager.Test.GitHubAPIMock.reset_mock_responses()

# Configure ExUnit
ExUnit.configure(capture_log: true)
ExUnit.start()

# Cleanup mock after all tests complete
ExUnit.after_suite(fn _ ->
  RegistryManager.Test.GitHubAPIMock.cleanup_mock()
end)
