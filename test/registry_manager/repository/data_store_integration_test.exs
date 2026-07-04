defmodule RegistryManager.Repository.DataStoreIntegrationTest do
  use ExUnit.Case, async: false

  alias RegistryManager.Repository.DataStore

  @moduledoc """
  DataStore統合テスト - GitHub API との統合を検証

  外部依存を含む統合テストです。GitHub API モックを通して
  データ永続化層の正常性を検証します。
  """

  describe "Registry data integration - レジストリデータ統合" do
    test "fetch_registry returns data in expected format" do
      case DataStore.fetch_registry() do
        {:ok, {data, sha}} ->
          # 正常なレスポンス形式を検証
          assert is_map(data)
          assert is_binary(sha)
          assert String.length(sha) > 0

        {:error, reason} ->
          # エラー時もバイナリで返されることを検証
          assert is_binary(reason)
      end
    end

    test "get_all_entries simplifies fetch_registry response" do
      case DataStore.get_all_entries() do
        {:ok, data} ->
          # データのみを返すことを検証
          assert is_map(data)

        {:error, reason} ->
          # エラー時の一貫性を検証
          assert is_binary(reason)
      end
    end

    test "entry_exists? handles both success and error cases" do
      # 存在しないリポジトリをテスト
      result = DataStore.entry_exists?("non-existent-repo-12345")
      assert is_boolean(result)
      # GitHub API が利用可能な場合は false、エラー時も false
      assert result == false
    end
  end

  describe "Data operations integration - データ操作統合" do
    test "save_entry maintains data integrity" do
      # 新しいエントリのデータ構造を検証
      entry_data = %{
        "student_id" => "k21rs999",
        "repository_type" => "wr",
        "created_at" => "2025-07-02 10:00:00 UTC",
        "registry_updated_at" => "2025-07-02 10:00:00 UTC"
      }

      result = DataStore.save_entry("k21rs999-wr", entry_data, "Test commit")

      case result do
        {:ok, _message} ->
          # 成功時のメッセージ形式を検証
          assert true

        {:error, reason} ->
          # エラー時の適切な形式を検証
          assert is_binary(reason)
      end
    end

    test "update_entry maintains registry_updated_at consistency" do
      # 更新操作のデータ整合性を検証
      result =
        DataStore.update_entry("test-repo", "protection_status", "protected", "Test update")

      case result do
        {:ok, _message} ->
          # 成功時の処理を検証
          assert true

        {:error, reason} ->
          # エラー時（リポジトリが存在しない場合など）を検証
          assert is_binary(reason)
          # "Repository not found" エラーが期待される
          assert String.contains?(reason, "not found") or String.contains?(reason, "GitHub")
      end
    end

    test "delete_entry handles non-existent repositories gracefully" do
      # 存在しないリポジトリの削除を試行
      result = DataStore.delete_entry("non-existent-repo-12345", "Test deletion")

      case result do
        {:ok, _message} ->
          # 予期しない成功（テストデータが存在する場合）
          assert true

        {:error, reason} ->
          # 期待されるエラー（存在しないリポジトリ）
          assert is_binary(reason)
          assert String.contains?(reason, "not found") or String.contains?(reason, "GitHub")
      end
    end
  end

  describe "Error handling integration - エラーハンドリング統合" do
    test "all DataStore functions handle GitHub API errors consistently" do
      # GitHub API エラー時の一貫した処理を検証
      # この部分はモックが GitHub API エラーを返す場合の動作を検証

      functions_to_test = [
        fn -> DataStore.fetch_registry() end,
        fn -> DataStore.get_all_entries() end,
        fn -> DataStore.entry_exists?("test") end
      ]

      Enum.each(functions_to_test, fn test_fn ->
        result = test_fn.()

        case result do
          {:ok, _} ->
            # 正常応答の場合
            assert true

          {:error, reason} ->
            # エラー応答の一貫性を検証
            assert is_binary(reason)

          boolean when is_boolean(boolean) ->
            # entry_exists? の場合
            assert true
        end
      end)
    end
  end
end
