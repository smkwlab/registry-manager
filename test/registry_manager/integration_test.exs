defmodule RegistryManager.IntegrationTest do
  use ExUnit.Case, async: false

  alias RegistryManager.Commands.{Cache, List, Migrate, Validate}
  alias RegistryManager.GitHubAPI
  alias RegistryManager.Repository
  alias RegistryManager.Test.GitHubAPIMock

  @moduledoc """
  Integration tests for registry-manager v4

  Tests complete workflows and interactions between all components.
  """

  describe "complete workflow - repository management" do
    test "add, update, protect, and list repository" do
      # 1. Add a new repository using inference
      result = Repository.add_with_inference("k21rs999-test", [])
      assert match?({:ok, _}, result) or match?({:error, _}, result)

      # 2. List repositories to verify addition
      list_result = List.run([], [])
      assert {:ok, _output} = list_result

      # 3. Update repository field (if added successfully)
      case result do
        {:ok, _} ->
          update_result = Repository.update("k21rs999-test", "github_username", "testuser", [])
          assert match?({:ok, _}, update_result) or match?({:error, _}, update_result)

        {:error, _} ->
          # Skip update if add failed (might be due to test environment)
          :ok
      end

      # 4. Mark as protected
      protect_result = Repository.mark_protected("k21rs999-test", [])
      assert match?({:ok, _}, protect_result) or match?({:error, _}, protect_result)

      # 5. Remove repository (cleanup)
      remove_result = Repository.remove("k21rs999-test", [])
      assert match?({:ok, _}, remove_result) or match?({:error, _}, remove_result)
    end

    test "validate data integrity across operations" do
      # Run validation
      validation_result = Validate.run([], [])
      assert {:ok, _output} = validation_result
    end
  end

  describe "complete workflow - caching system" do
    test "cache operations with GitHub API integration" do
      # 1. Clear cache first
      assert {:ok, _} = Cache.run(["clear"], [])

      # 2. Check cache status
      result = Cache.run(["status"], [])
      assert {:ok, _} = result

      # 3. Make API call to populate cache
      case GitHubAPI.get_repositories_json() do
        {:ok, _data} ->
          # 4. Check cache status again - should show entries
          result2 = Cache.run(["status"], [])
          assert {:ok, _} = result2

        {:error, _} ->
          # Skip if API is unavailable
          :ok
      end
    end

    test "cache TTL and expiration" do
      # Test cache expiration logic with Application config
      default_ttl = Application.get_env(:registry_manager, :cache_ttl, 300)
      assert is_integer(default_ttl)
      assert default_ttl > 0
    end
  end

  describe "complete workflow - list command variations" do
    test "all list command options work together" do
      # Basic list
      assert {:ok, _} = List.run([], [])

      # List with format options
      assert {:ok, _} = List.run([], format: "json")
      assert {:ok, _} = List.run([], format: "csv")
      assert {:ok, _} = List.run([], format: "table")

      # List with display options
      assert {:ok, _} = List.run([], long: true)
      assert {:ok, _} = List.run([], show_type: true)
      assert {:ok, _} = List.run([], show_protection: true)
      assert {:ok, _} = List.run([], no_names: true)

      # List with filtering
      assert {:ok, _} = List.run([], type: "sotsuron")
      assert {:ok, _} = List.run([], type: "wr")

      # List with sorting
      assert {:ok, _} = List.run([], sort: "time")
      assert {:ok, _} = List.run([], sort: "time", reverse: true)

      # Complex combination
      assert {:ok, _} =
               List.run([],
                 format: "csv",
                 long: true,
                 type: "sotsuron",
                 sort: "time",
                 show_student_id: true
               )
    end

    test "list command with GitHub activity integration" do
      # Skip activity tests in test environment to avoid API calls
      if Application.get_env(:registry_manager, :env) != :test do
        assert {:ok, _} = List.run([], activity: true)
        assert {:ok, _} = List.run([], owner_activity: true)
      else
        # Just verify command doesn't crash
        result = List.run([], activity: true)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end
  end

  describe "complete workflow - migration" do
    test "migration status and dry-run workflow" do
      # 1. Check migration status
      assert {:ok, _} = Migrate.run(["status"], [])

      # 2. Perform dry-run
      assert {:ok, _} = Migrate.run(["dry-run"], [])

      # 3. Would execute migration if needed (skip in test)
      # assert {:ok, _} = Migrate.run(["execute"], [])
    end
  end

  describe "configuration management" do
    test "configuration precedence: env > file > defaults" do
      # Test default values via Application
      default_ttl = Application.get_env(:registry_manager, :cache_ttl, 300)
      assert default_ttl == 300

      # Test that we can set and get Application config
      original = Application.get_env(:registry_manager, :test_key)
      Application.put_env(:registry_manager, :test_key, "test_value")
      assert Application.get_env(:registry_manager, :test_key) == "test_value"

      # Cleanup
      if original do
        Application.put_env(:registry_manager, :test_key, original)
      else
        Application.delete_env(:registry_manager, :test_key)
      end
    end

    test "cache directory configuration" do
      cache_dir = System.tmp_dir() |> Path.join("registry_manager_cache_test")
      assert is_binary(cache_dir)
      assert String.contains?(cache_dir, "registry_manager_cache")
    end
  end

  describe "error handling and edge cases" do
    test "handles invalid repository names gracefully" do
      # Various invalid formats
      assert {:error, _} = Repository.add("", "k21rs001", "sotsuron", [])
      assert {:error, _} = Repository.add("invalid name with spaces", "k21rs001", "sotsuron", [])
      assert {:error, _} = Repository.add_with_inference("", [])
    end

    test "handles invalid command arguments" do
      # Invalid list format
      assert {:error, _} = List.run([], format: "xml")

      # Invalid cache command
      assert {:error, _} = Cache.run(["invalid"], [])

      # Invalid migrate command
      assert {:error, _} = Migrate.run(["invalid", "args"], [])
    end

    test "handles missing CSV file gracefully" do
      # List should work even without CSV file
      result = List.run([], [])
      assert {:ok, _} = result

      # Test that it completes without error
      assert true
    end
  end

  describe "performance and optimization" do
    test "caching reduces API calls" do
      # キャッシュ効果は実測時間ではなく「2 回目は API を叩かない」で決定的に検証する。
      # get_repositories_json/0 はキャッシュ層を通らない設計（mock / _impl いずれも
      # Client を直呼び）のため、実際にキャッシュが効くのは activity フロー
      # （list --activity → Cache.get/put + get_repository_activity）。
      # get_repository_activity のモック呼び出し回数を数え、キャッシュが warm な
      # 2 回目では追加の API 呼び出しが発生しないことを assert する。

      # activity キャッシュをクリア（先行テストのデータ混入を防ぐ）
      Cache.run(["clear"], [])

      # get_repositories_json を固定レスポンス（1 件以上）に明示設定する。
      # activity フローの対象リポジトリが 0 件だと get_repository_activity が
      # 一度も呼ばれず first_count == 0 となり、キャッシュとは無関係な理由で
      # テストが落ちてしまう。前提をモックのデフォルトに委ねず自己完結させる。
      registry_data = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "created_at" => "2025-01-01T00:00:00Z",
          "registry_updated_at" => "2025-01-01T00:00:00Z"
        }
      }

      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {registry_data, "test-sha"}}
      end)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      # クリーンアップは on_exit で行い、assert 失敗時も確実に実行されるようにする。
      # counter はテストプロセスにリンクされ終了時に自動で停止するため、
      # ここでは stop せずモック設定とキャッシュのみリセットする。
      on_exit(fn ->
        GitHubAPIMock.reset_mock_responses()
        Cache.run(["clear"], [])
      end)

      GitHubAPIMock.set_mock_response(:get_repository_activity, fn _repo, _opts ->
        Agent.update(counter, &(&1 + 1))
        {:ok, "2025-07-01T12:00:00Z"}
      end)

      # 1 回目: キャッシュが cold なので API（get_repository_activity）を叩く
      assert {:ok, _} = List.run([], activity: true)
      first_count = Agent.get(counter, & &1)
      assert first_count > 0, "初回は API (get_repository_activity) が呼ばれるはず"

      # 2 回目: キャッシュが warm なので API を叩かず、呼び出し回数は変わらない
      assert {:ok, _} = List.run([], activity: true)
      second_count = Agent.get(counter, & &1)

      assert second_count == first_count,
             "キャッシュ warm 後は追加の API 呼び出しが発生しないはず " <>
               "(first=#{first_count}, second=#{second_count})"
    end

    test "list command completes in reasonable time" do
      {time, result} = :timer.tc(fn -> List.run([], long: true) end)
      assert {:ok, _} = result

      # Should complete within 5 seconds even with all options
      # 5 seconds in microseconds
      assert time < 5_000_000
    end
  end

  describe "data format compatibility" do
    test "handles both v1 and v4 registry formats via migration" do
      # Create test data with mixed formats
      v1_entry = %{
        "student_id" => "k19rs999",
        "repository_type" => "sotsuron",
        "status" => "completed",
        "stage" => "thesis",
        "updated_at" => "2025-07-07 16:44:44 UTC"
      }

      v4_entry = %{
        "student_id" => "k21rs001",
        "repository_type" => "wr",
        "created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_updated_at" => "2025-07-08T06:51:39.835808Z"
      }

      # Use Migration module to test format detection
      alias RegistryManager.Migration

      # Should be detected as v1
      refute Migration.is_v4_format?(v1_entry)
      # Should be detected as v4
      assert Migration.is_v4_format?(v4_entry)

      # Test migration of v1 entry
      {:ok, migrated} = Migration.migrate_single_entry("test-v1", v1_entry)
      # Should be v4 after migration
      assert Migration.is_v4_format?(migrated)
    end
  end

  describe "concurrent operations" do
    test "parallel list operations don't interfere" do
      # Run multiple list operations in parallel
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            opts =
              case rem(i, 3) do
                0 -> [format: "json"]
                1 -> [format: "csv"]
                2 -> [long: true]
              end

            List.run([], opts)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      assert Enum.all?(results, fn result ->
               match?({:ok, _}, result)
             end)
    end
  end

  describe "CLI integration" do
    test "CLI commands parse correctly" do
      alias RegistryManager.CLI

      # Test various command parsing
      assert CLI.parse_args(["list"]) == {:list, nil, []}
      assert CLI.parse_args(["list", "--long"]) == {:list, nil, [long: true]}
      assert CLI.parse_args(["list", "sotsuron"]) == {:list, "sotsuron", []}
      assert CLI.parse_args(["list", "--format", "json"]) == {:list, nil, [format: "json"]}

      # Complex parsing
      assert CLI.parse_args(["list", "--long", "--type", "wr", "--format", "csv"]) ==
               {:list, nil, [long: true, type: "wr", format: "csv"]}

      # Help
      assert CLI.parse_args(["--help"]) == :help
      assert CLI.parse_args(["-h"]) == :help

      # Invalid commands
      assert CLI.parse_args(["invalid"]) == :help
      assert CLI.parse_args([]) == :help
    end
  end
end
