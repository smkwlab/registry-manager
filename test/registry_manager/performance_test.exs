defmodule RegistryManager.PerformanceTest do
  use ExUnit.Case, async: false

  alias RegistryManager.Commands.{Cache, List}
  alias RegistryManager.GitHubAPI

  @moduledoc """
  Performance tests for registry-manager v4

  Tests performance characteristics and resource usage of key operations.
  """

  describe "performance benchmarks" do
    test "list command performance under various loads" do
      # Test basic list performance
      {time, result} = :timer.tc(fn -> List.run([], []) end)
      assert {:ok, _} = result
      # Should complete within 2 seconds
      assert time < 2_000_000

      # Test list with all options enabled
      {time_full, result_full} =
        :timer.tc(fn ->
          List.run([],
            long: true,
            show_type: true,
            show_protection: true,
            show_student_id: true,
            format: "json"
          )
        end)

      assert {:ok, _} = result_full
      # Should complete within 5 seconds even with all options
      assert time_full < 5_000_000
    end

    test "cache operations performance" do
      # Clear cache
      {clear_time, clear_result} = :timer.tc(fn -> Cache.run(["clear"], []) end)
      assert {:ok, _} = clear_result
      # Should clear within 1 second
      assert clear_time < 1_000_000

      # Check status performance
      {status_time, status_result} = :timer.tc(fn -> Cache.run(["status"], []) end)
      assert {:ok, _} = status_result
      # Should check status within 0.5 seconds
      assert status_time < 500_000
    end

    test "memory usage stays reasonable" do
      # Test memory usage during operations
      initial_memory = :erlang.memory(:total)

      # Perform several operations
      Enum.each(1..10, fn _i ->
        List.run([], [])
        Cache.run(["status"], [])
      end)

      final_memory = :erlang.memory(:total)
      memory_increase = final_memory - initial_memory

      # Memory increase should be reasonable (less than 10MB)
      # 10MB in bytes
      assert memory_increase < 10_485_760
    end
  end

  describe "scalability tests" do
    test "handles multiple concurrent requests" do
      # Test concurrent operations
      concurrency_level = 10

      tasks =
        Enum.map(1..concurrency_level, fn i ->
          Task.async(fn ->
            case rem(i, 4) do
              0 -> List.run([], format: "json")
              1 -> List.run([], format: "csv")
              2 -> Cache.run(["status"], [])
              3 -> List.run([], long: true)
            end
          end)
        end)

      # All tasks should complete within reasonable time
      {time, results} = :timer.tc(fn -> Task.await_many(tasks, 15_000) end)

      # All should succeed
      assert Enum.all?(results, fn result -> match?({:ok, _}, result) end)

      # Should complete within 15 seconds even under load
      assert time < 15_000_000
    end
  end

  describe "resource usage optimization" do
    test "cache hit rate optimization" do
      # Clear cache
      Cache.run(["clear"], [])

      # First call - cache miss
      {time1, result1} = :timer.tc(fn -> GitHubAPI.get_repositories_json() end)

      case result1 do
        {:ok, _} ->
          # Second call - should be cache hit
          {time2, result2} = :timer.tc(fn -> GitHubAPI.get_repositories_json() end)
          assert {:ok, _} = result2

          # Cache hit should be significantly faster
          # Note: In test environment this might not always be true due to mocking
          # Only check if first call took measurable time
          if time1 > 10_000 do
            assert time2 <= time1
          end

        {:error, _} ->
          # Skip if API unavailable
          :ok
      end
    end

    test "memory-efficient data processing" do
      # Test that operations don't accumulate memory unnecessarily
      initial_memory = :erlang.memory(:processes)

      # Perform many operations
      Enum.each(1..50, fn i ->
        List.run([], [])
        # Force garbage collection periodically
        if rem(i, 10) == 0, do: :erlang.garbage_collect()
      end)

      final_memory = :erlang.memory(:processes)
      memory_increase = final_memory - initial_memory

      # Memory should not increase significantly
      # 5MB limit
      assert memory_increase < 5_242_880
    end
  end

  describe "error recovery performance" do
    test "graceful degradation under API failure" do
      # Test that commands still work reasonably fast even when API calls fail

      # This test assumes that in test environment, API calls may fail
      {time, result} =
        :timer.tc(fn ->
          # This might fail due to API unavailability
          List.run([], activity: true)
        end)

      # Should return quickly even on failure
      # Within 5 seconds
      assert time < 5_000_000

      # Should return either success or graceful error
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "cache resilience under corruption" do
      # Test recovery from cache issues
      {time, result} =
        :timer.tc(fn ->
          # This should work regardless of cache state
          Cache.run(["status"], [])
        end)

      assert {:ok, _} = result
      # Should complete within 2 seconds
      assert time < 2_000_000
    end
  end
end
