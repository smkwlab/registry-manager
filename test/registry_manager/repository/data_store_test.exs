defmodule RegistryManager.Repository.DataStoreTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias RegistryManager.Repository.DataStore
  alias RegistryManager.Test.GitHubAPIMock

  @moduledoc """
  DataStore単体テスト - GitHubAPIをモックしてビジネスロジックを検証

  外部依存を排除したDataStoreのロジックテストです。
  すべての関数のハッピーパスとエラーケースを網羅します。
  """

  # テストデータ
  @test_entry_data %{
    "student_id" => "k21rs001",
    "repository_type" => "sotsuron",
    "repository_created_at" => "2025-07-01T00:00:00.000000Z",
    "registry_created_at" => "2025-07-01T00:00:00.000000Z",
    "registry_updated_at" => "2025-07-01T00:00:00.000000Z"
  }

  @test_registry_data %{
    "k21rs001-sotsuron" => @test_entry_data,
    "k21rs002-wr" => %{
      "student_id" => "k21rs002",
      "repository_type" => "wr",
      "repository_created_at" => "2025-07-01T00:00:00.000000Z",
      "registry_created_at" => "2025-07-01T00:00:00.000000Z",
      "registry_updated_at" => "2025-07-01T00:00:00.000000Z"
    }
  }

  @test_sha "abc123def456"

  setup do
    # モックセットアップ
    GitHubAPIMock.setup_mock()
    GitHubAPIMock.clear_mock_responses()

    on_exit(fn ->
      GitHubAPIMock.cleanup_mock()
    end)

    :ok
  end

  describe "fetch_registry/0" do
    test "delegates to GitHubAPI.get_repositories_json/0" do
      # GitHubAPIモックレスポンスを設定
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      result = DataStore.fetch_registry()

      assert {:ok, {@test_registry_data, @test_sha}} = result
    end

    test "returns error when GitHubAPI fails" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:error, "API error"}
      end)

      result = DataStore.fetch_registry()

      assert {:error, "API error"} = result
    end
  end

  describe "save_entry/3" do
    test "saves new entry successfully" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _data, _sha, _message ->
        {:ok, "Entry saved"}
      end)

      result = DataStore.save_entry("k21rs003-ise", @test_entry_data, "Add new entry")

      assert {:ok, "Entry saved"} = result
    end

    test "returns error when fetch_registry fails" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:error, "Network error"}
      end)

      result = DataStore.save_entry("k21rs003-ise", @test_entry_data, "Add new entry")

      assert {:error, "Failed to save entry for k21rs003-ise: Network error"} = result
    end

    test "returns error when update fails" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _data, _sha, _message ->
        {:error, "Update failed"}
      end)

      result = DataStore.save_entry("k21rs003-ise", @test_entry_data, "Add new entry")

      assert {:error, "Update failed"} = result
    end
  end

  describe "update_entry/4" do
    test "updates existing entry successfully" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _data, _sha, _message ->
        {:ok, "Entry updated"}
      end)

      result =
        DataStore.update_entry(
          "k21rs001-sotsuron",
          "protection_status",
          "protected",
          "Update field"
        )

      assert {:ok, "Entry updated"} = result
    end

    test "returns error when repository does not exist" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      result = DataStore.update_entry("non-existent-repo", "field", "value", "Update field")

      assert {:error,
              "Failed to update entry for non-existent-repo: Repository not found: non-existent-repo"} =
               result
    end

    test "returns error when fetch_registry fails" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:error, "Network error"}
      end)

      result = DataStore.update_entry("k21rs001-sotsuron", "field", "value", "Update field")

      assert {:error, "Failed to update entry for k21rs001-sotsuron: Network error"} = result
    end

    test "returns error when update fails" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _data, _sha, _message ->
        {:error, "Update failed"}
      end)

      result =
        DataStore.update_entry(
          "k21rs001-sotsuron",
          "protection_status",
          "protected",
          "Update field"
        )

      assert {:error, "Update failed"} = result
    end
  end

  describe "delete_entry/2" do
    test "deletes existing entry successfully" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _data, _sha, _message ->
        {:ok, "Entry deleted"}
      end)

      result = DataStore.delete_entry("k21rs001-sotsuron", "Delete entry")

      assert {:ok, "Entry deleted"} = result
    end

    test "returns error when repository does not exist" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      result = DataStore.delete_entry("non-existent-repo", "Delete entry")

      assert {:error,
              "Failed to delete entry for non-existent-repo: Repository not found: non-existent-repo"} =
               result
    end

    test "returns error when fetch_registry fails" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:error, "Network error"}
      end)

      result = DataStore.delete_entry("k21rs001-sotsuron", "Delete entry")

      assert {:error, "Failed to delete entry for k21rs001-sotsuron: Network error"} = result
    end

    test "returns error when update fails" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _data, _sha, _message ->
        {:error, "Delete failed"}
      end)

      result = DataStore.delete_entry("k21rs001-sotsuron", "Delete entry")

      assert {:error, "Delete failed"} = result
    end
  end

  describe "entry_exists?/1" do
    test "returns true when entry exists" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      result = DataStore.entry_exists?("k21rs001-sotsuron")

      assert result == true
    end

    test "returns false when entry does not exist" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      result = DataStore.entry_exists?("non-existent-repo")

      assert result == false
    end

    test "returns false and logs warning when fetch_registry fails" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:error, "Network error"}
      end)

      log_output =
        capture_log(fn ->
          result = DataStore.entry_exists?("k21rs001-sotsuron")
          assert result == false
        end)

      assert String.contains?(log_output, "Failed to check entry existence for k21rs001-sotsuron")
      assert String.contains?(log_output, "Network error")
    end
  end

  describe "get_all_entries/0" do
    test "returns all entries successfully" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      result = DataStore.get_all_entries()

      assert {:ok, @test_registry_data} = result
    end

    test "returns error when fetch_registry fails" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:error, "Network error"}
      end)

      result = DataStore.get_all_entries()

      assert {:error, "Network error"} = result
    end
  end

  describe "save_all_entries/2" do
    test "saves all entries successfully" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {%{}, @test_sha}}
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _data, _sha, _message ->
        {:ok, "All entries saved"}
      end)

      result = DataStore.save_all_entries(@test_registry_data, "Save all entries")

      assert {:ok, "All entries saved"} = result
    end

    test "returns error when fetch_registry fails" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:error, "Network error"}
      end)

      result = DataStore.save_all_entries(@test_registry_data, "Save all entries")

      assert {:error, "Failed to save all entries: Network error"} = result
    end

    test "returns error when update fails" do
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {%{}, @test_sha}}
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _data, _sha, _message ->
        {:error, "Update failed"}
      end)

      result = DataStore.save_all_entries(@test_registry_data, "Save all entries")

      assert {:error, "Update failed"} = result
    end
  end

  describe "save_registry/3" do
    test "saves registry with provided SHA successfully" do
      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _data, _sha, _message ->
        {:ok, "Registry saved"}
      end)

      result = DataStore.save_registry(@test_registry_data, @test_sha, "Save registry")

      assert {:ok, "Registry saved"} = result
    end

    test "returns error when update fails" do
      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _data, _sha, _message ->
        {:error, "Update failed"}
      end)

      result = DataStore.save_registry(@test_registry_data, @test_sha, "Save registry")

      assert {:error, "Update failed"} = result
    end
  end

  describe "get_existing_entry/2 (private function behavior)" do
    test "update_entry properly handles existing entry lookup" do
      # プライベート関数の挙動を間接的にテスト
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _data, _sha, _message ->
        {:ok, "Entry updated"}
      end)

      result =
        DataStore.update_entry(
          "k21rs001-sotsuron",
          "protection_status",
          "protected",
          "Update field"
        )

      assert {:ok, "Entry updated"} = result
    end

    test "delete_entry properly handles existing entry lookup" do
      # プライベート関数の挙動を間接的にテスト
      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {@test_registry_data, @test_sha}}
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _data, _sha, _message ->
        {:ok, "Entry deleted"}
      end)

      result = DataStore.delete_entry("k21rs001-sotsuron", "Delete entry")

      assert {:ok, "Entry deleted"} = result
    end
  end
end
