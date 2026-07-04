defmodule RegistryManager.Repository.ErrorHandlerTest do
  use ExUnit.Case, async: true

  alias RegistryManager.Repository.ErrorHandler

  describe "handle_validation_result/1" do
    test "handles successful validation" do
      stats = %{
        total_entries: 10,
        valid_entries: 10
      }

      result = ErrorHandler.handle_validation_result({:ok, stats})

      assert {:ok, output} = result
      assert String.contains?(output, "データ整合性検証完了")
      assert String.contains?(output, "総エントリ数: 10")
      assert String.contains?(output, "有効エントリ数: 10")
    end

    test "handles validation errors" do
      errors = [
        "Invalid student ID: invalid-id",
        "Missing required field: status"
      ]

      result = ErrorHandler.handle_validation_result({:error, errors})

      assert {:error, output} = result
      assert String.contains?(output, "データ整合性検証で問題が見つかりました")
      assert String.contains?(output, "エラー詳細 (2件)")
      assert String.contains?(output, "1. Invalid student ID: invalid-id")
      assert String.contains?(output, "2. Missing required field: status")
    end
  end

  describe "handle_github_api_error/1" do
    test "handles GitHub API errors" do
      error_tuple = {:error, "Authentication failed"}

      result = ErrorHandler.handle_github_api_error(error_tuple)

      assert {:error, output} = result
      assert String.contains?(output, "リポジトリデータの取得に失敗: Authentication failed")
    end

    test "handles network timeout errors" do
      error_tuple = {:error, "Request timeout"}

      result = ErrorHandler.handle_github_api_error(error_tuple)

      assert {:error, output} = result
      assert String.contains?(output, "リポジトリデータの取得に失敗: Request timeout")
    end
  end

  describe "handle_repository_not_found/1" do
    test "handles repository not found error" do
      repo_name = "k21rs001-nonexistent"

      result = ErrorHandler.handle_repository_not_found(repo_name)

      assert {:error, output} = result
      assert output == "Repository not found: k21rs001-nonexistent"
    end

    test "handles empty repository name" do
      repo_name = ""

      result = ErrorHandler.handle_repository_not_found(repo_name)

      assert {:error, output} = result
      assert output == "Repository not found: "
    end
  end
end
