defmodule RegistryManager.Repository.DisplayTest do
  use ExUnit.Case, async: true

  alias RegistryManager.Repository.Display

  describe "format_statistics/1" do
    test "formats statistics correctly" do
      stats = %{
        total: 10,
        type: %{"wr" => 7, "sotsuron" => 3},
        protected: 5
      }

      result = Display.format_statistics(stats)

      assert String.contains?(result, "総リポジトリ数: 10")
      assert String.contains?(result, "wr: 7")
      assert String.contains?(result, "sotsuron: 3")
      assert String.contains?(result, "保護設定済み: 5")
    end

    test "handles missing status counts" do
      stats = %{
        total: 5,
        type: %{"wr" => 2},
        protected: 1
      }

      result = Display.format_statistics(stats)

      assert String.contains?(result, "総リポジトリ数: 5")
      assert String.contains?(result, "wr: 2")
      assert String.contains?(result, "保護設定済み: 1")
    end
  end

  describe "format_validation_success/1" do
    test "formats validation success correctly" do
      stats = %{
        total_entries: 15,
        valid_entries: 15
      }

      result = Display.format_validation_success(stats)

      assert String.contains?(result, "データ整合性検証完了")
      assert String.contains?(result, "総エントリ数: 15")
      assert String.contains?(result, "有効エントリ数: 15")
      assert String.contains?(result, "エラー: 0件")
      assert String.contains?(result, "すべてのデータが正常です")
    end
  end

  describe "format_validation_errors/1" do
    test "formats single error correctly" do
      errors = ["Invalid student ID: invalid-id"]

      result = Display.format_validation_errors(errors)

      assert String.contains?(result, "データ整合性検証で問題が見つかりました")
      assert String.contains?(result, "エラー詳細 (1件)")
      assert String.contains?(result, "1. Invalid student ID: invalid-id")
      assert String.contains?(result, "上記の問題を修正してください")
    end

    test "formats multiple errors correctly" do
      errors = [
        "Invalid student ID: invalid-id",
        "Invalid repository type: invalid-type",
        "Missing required field: status"
      ]

      result = Display.format_validation_errors(errors)

      assert String.contains?(result, "エラー詳細 (3件)")
      assert String.contains?(result, "1. Invalid student ID: invalid-id")
      assert String.contains?(result, "2. Invalid repository type: invalid-type")
      assert String.contains?(result, "3. Missing required field: status")
    end
  end

  describe "format_repository_list/2" do
    test "formats list without filter" do
      formatted_list = "{\"repo1\": {\"status\": \"active\"}}"

      result = Display.format_repository_list(formatted_list, nil)

      assert String.contains?(result, "リポジトリ一覧")
      assert String.contains?(result, formatted_list)
      refute String.contains?(result, "フィルター")
    end

    test "formats list with filter" do
      formatted_list = "{\"repo1\": {\"status\": \"active\"}}"

      result = Display.format_repository_list(formatted_list, "active")

      assert String.contains?(result, "リポジトリ一覧 (フィルター: active)")
      assert String.contains?(result, formatted_list)
    end
  end

  describe "format_repository_info/2" do
    test "formats repository info correctly" do
      repo_name = "k21rs001-sotsuron"

      repo_info = %{
        "student_id" => "k21rs001",
        "repository_type" => "sotsuron",
        "status" => "active",
        "stage" => "thesis"
      }

      result = Display.format_repository_info(repo_name, repo_info)

      assert String.contains?(result, "リポジトリ状況: k21rs001-sotsuron")
      assert String.contains?(result, "k21rs001")
      assert String.contains?(result, "sotsuron")
      assert String.contains?(result, "active")
      assert String.contains?(result, "thesis")
    end

    test "handles empty repository info" do
      repo_name = "empty-repo"
      repo_info = %{}

      result = Display.format_repository_info(repo_name, repo_info)

      assert String.contains?(result, "リポジトリ状況: empty-repo")
      assert String.contains?(result, "{}")
    end

    test "handles JSON encoding errors gracefully" do
      repo_name = "error-repo"
      # Create data that would cause JSON encoding issues
      # PIDs cannot be JSON encoded
      repo_info = %{pid: self()}

      result = Display.format_repository_info(repo_name, repo_info)

      assert String.contains?(result, "リポジトリ状況: error-repo")
      assert String.contains?(result, "[データ形式エラー]")
    end
  end
end
