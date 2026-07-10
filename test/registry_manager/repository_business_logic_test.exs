defmodule RegistryManager.RepositoryBusinessLogicTest do
  use ExUnit.Case, async: true

  alias RegistryManager.Repository

  @moduledoc """
  Repository ビジネスロジックの品質テスト

  外部依存を排除し、純粋なビジネスロジックのみをテストします。
  DataStoreへの依存は最小限に抑え、ビジネスルールの正確性を検証します。
  """

  describe "build_new_entry/3 - データ構築ビジネスロジック" do
    test "creates correct entry structure with all required fields" do
      student_id = "k21rs001"
      repo_type = "wr"
      timestamp = "2025-07-02 10:00:00 UTC"

      result = Repository.build_new_entry(student_id, repo_type, timestamp)

      assert result == %{
               "student_id" => "k21rs001",
               "repository_type" => "wr",
               "created_at" => "2025-07-02 10:00:00 UTC",
               "registry_updated_at" => "2025-07-02 10:00:00 UTC"
             }
    end

    test "works with all valid repository types" do
      valid_types = ["wr", "ise-report", "sotsuron"]
      timestamp = "2025-07-02 10:00:00 UTC"

      Enum.each(valid_types, fn repo_type ->
        result = Repository.build_new_entry("k21rs001", repo_type, timestamp)

        assert result["repository_type"] == repo_type
        assert result["student_id"] == "k21rs001"
        assert result["created_at"] == timestamp
        assert result["registry_updated_at"] == timestamp
      end)
    end

    test "ensures created_at and registry_updated_at are identical for new entries" do
      result = Repository.build_new_entry("k21rs001", "wr", "2025-07-02 10:00:00 UTC")

      assert result["created_at"] == result["registry_updated_at"]
    end

    test "includes github_username when provided" do
      student_id = "k21rs001"
      repo_type = "wr"
      timestamp = "2025-07-02 10:00:00 UTC"
      github_username = "test-taro"

      result = Repository.build_new_entry(student_id, repo_type, timestamp, github_username)

      assert result == %{
               "student_id" => "k21rs001",
               "repository_type" => "wr",
               "created_at" => "2025-07-02 10:00:00 UTC",
               "registry_updated_at" => "2025-07-02 10:00:00 UTC",
               "github_username" => "test-taro"
             }
    end

    test "omits github_username when nil" do
      result = Repository.build_new_entry("k21rs001", "wr", "2025-07-02 10:00:00 UTC", nil)

      refute Map.has_key?(result, "github_username")
    end

    test "omits github_username when empty string" do
      result = Repository.build_new_entry("k21rs001", "wr", "2025-07-02 10:00:00 UTC", "")

      refute Map.has_key?(result, "github_username")
    end
  end

  describe "validate_add_request/3 - バリデーションビジネスロジック" do
    test "accepts valid student ID, repository name, and type combinations" do
      valid_cases = [
        {"k21rs001-wr", "k21rs001", "wr"},
        {"k92jk123-sotsuron", "k92jk123", "sotsuron"},
        {"k91gjk01-ise-report", "k91gjk01", "ise-report"},
        {"k23rs999-sotsuron", "k23rs999", "sotsuron"},
        {"k21rs001-ise", "k21rs001", "ise"},
        {"k94gjk01-master", "k94gjk01", "master"},
        {"k21rs001-poster", "k21rs001", "other"}
      ]

      Enum.each(valid_cases, fn {repo_name, student_id, repo_type} ->
        assert Repository.validate_add_request(repo_name, student_id, repo_type) == :ok
      end)
    end

    test "rejects invalid student ID formats" do
      invalid_student_ids = [
        "invalid",
        "k21",
        "21rs001",
        "k21rs",
        "k21rs1",
        "K21RS001",
        ""
      ]

      Enum.each(invalid_student_ids, fn student_id ->
        result = Repository.validate_add_request("#{student_id}-wr", student_id, "wr")
        assert {:error, _reason} = result
      end)
    end

    test "rejects mismatched repository names" do
      # Repository name doesn't match student ID
      result = Repository.validate_add_request("k21rs002-wr", "k21rs001", "wr")
      assert {:error, _reason} = result
    end

    test "rejects invalid repository types" do
      invalid_types = ["invalid", "report", "", "WR", "LATEX", "unknown"]

      Enum.each(invalid_types, fn repo_type ->
        result = Repository.validate_add_request("k21rs001-wr", "k21rs001", repo_type)
        assert {:error, _reason} = result
      end)
    end
  end

  describe "get_validated_timestamp/1 - タイムスタンプビジネスロジック" do
    test "generates current timestamp when no timestamp option provided" do
      {:ok, timestamp} = Repository.get_validated_timestamp([])

      # UTC形式の文字列であることを確認
      assert String.match?(timestamp, ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z$/)

      # 現在時刻に近いことを確認（1分以内）
      {:ok, parsed_time, _} = DateTime.from_iso8601(timestamp)
      now = DateTime.utc_now()
      diff = DateTime.diff(now, parsed_time, :second)
      assert abs(diff) < 60
    end

    test "validates and accepts correctly formatted custom timestamps" do
      valid_timestamps = [
        "2025-07-02 10:00:00 UTC",
        "2025-01-01 00:00:00 UTC",
        "2025-12-31 23:59:59 UTC"
      ]

      Enum.each(valid_timestamps, fn timestamp ->
        assert {:ok, ^timestamp} = Repository.get_validated_timestamp(timestamp: timestamp)
      end)
    end

    test "rejects invalid timestamp formats" do
      invalid_timestamps = [
        # Missing UTC
        "2025-07-02 10:00:00",
        # Single digit month/day
        "2025-7-2 10:00:00 UTC",
        # ISO format
        "2025-07-02T10:00:00Z",
        # Wrong format
        "July 2, 2025 10:00:00",
        # Invalid month
        "2025-13-01 10:00:00 UTC",
        # Invalid date
        "2025-02-30 10:00:00 UTC",
        # Invalid hour
        "2025-07-02 25:00:00 UTC",
        # Completely invalid
        "invalid",
        # Empty string
        ""
      ]

      Enum.each(invalid_timestamps, fn timestamp ->
        result = Repository.get_validated_timestamp(timestamp: timestamp)
        assert {:error, _reason} = result
      end)
    end

    test "rejects non-string timestamp values" do
      invalid_values = [123, :atom, %{}, []]

      Enum.each(invalid_values, fn value ->
        result = Repository.get_validated_timestamp(timestamp: value)
        assert {:error, "Timestamp must be a string"} = result
      end)
    end
  end

  describe "build_commit_message/5-6 - コミットメッセージビジネスロジック" do
    test "builds basic commit message with all required information" do
      result =
        Repository.build_commit_message(
          "Add repository: k21rs001-wr",
          "k21rs001-wr",
          "k21rs001",
          "wr",
          "registry-manager"
        )

      assert String.contains?(result, "Add repository: k21rs001-wr")
      assert String.contains?(result, "Repository: k21rs001-wr")
      # Masked
      assert String.contains?(result, "Student ID: k2******")
      assert String.contains?(result, "Type: wr")
      assert String.contains?(result, "Updated:")
      assert String.contains?(result, "Processed via registry-manager")
    end

    test "masks student ID for privacy" do
      result =
        Repository.build_commit_message(
          "Test",
          "k21rs001-wr",
          "k21rs001",
          "wr",
          "test-tool"
        )

      assert String.contains?(result, "Student ID: k2******")
      # Repository name is still shown but student ID is masked
      assert String.contains?(result, "Repository: k21rs001-wr")
      # Student ID itself should be masked where it appears
      refute String.match?(result, ~r/Student ID: k21rs001/)
    end

    test "includes change detail when provided" do
      result =
        Repository.build_commit_message(
          "Update repository: k21rs001-wr",
          "k21rs001-wr",
          "k21rs001",
          "wr",
          "registry-manager",
          "protection_status = protected"
        )

      assert String.contains?(result, "Change: protection_status = protected")
      assert String.contains?(result, "Processed via registry-manager")
    end

    test "handles different repository types correctly" do
      types = ["wr", "sotsuron", "ise-report"]

      Enum.each(types, fn repo_type ->
        result =
          Repository.build_commit_message(
            "Test",
            "k21rs001-#{repo_type}",
            "k21rs001",
            repo_type,
            "test-tool"
          )

        assert String.contains?(result, "Type: #{repo_type}")
      end)
    end
  end

  describe "calculate_statistics/1 - 統計計算ビジネスロジック" do
    test "calculates correct statistics for mixed data" do
      data = %{
        "k21rs001-wr" => %{
          "repository_type" => "wr",
          "protection_status" => "protected"
        },
        "k21rs002-wr" => %{
          "repository_type" => "wr",
          "protection_status" => "unprotected"
        },
        "k21rs003-sotsuron" => %{
          "repository_type" => "sotsuron",
          "protection_status" => "protected"
        }
      }

      result = Repository.calculate_statistics(data)

      assert result.total == 3
      assert result.type == %{"wr" => 2, "sotsuron" => 1}
      assert result.protected == 2
    end

    test "handles empty data correctly" do
      result = Repository.calculate_statistics(%{})

      assert result.total == 0
      assert result.type == %{}
      assert result.protected == 0
    end

    test "handles data with no protected repositories" do
      data = %{
        "k21rs001-wr" => %{
          "repository_type" => "wr",
          "protection_status" => "unprotected"
        },
        "k21rs002-wr" => %{
          "repository_type" => "wr"
          # No protection_status field
        }
      }

      result = Repository.calculate_statistics(data)

      assert result.total == 2
      assert result.type == %{"wr" => 2}
      assert result.protected == 0
    end

    test "counts only 'protected' status as protected" do
      data = %{
        "repo1" => %{
          "repository_type" => "wr",
          "protection_status" => "protected"
        },
        "repo2" => %{
          "repository_type" => "wr",
          "protection_status" => "unprotected"
        },
        "repo3" => %{
          "repository_type" => "wr",
          "protection_status" => "pending"
        },
        "repo4" => %{
          "repository_type" => "wr",
          "protection_status" => nil
        }
      }

      result = Repository.calculate_statistics(data)

      assert result.total == 4
      # Only "protected" counts
      assert result.protected == 1
    end
  end

  describe "build_github_deletion_command/1 - GitHub削除コマンド生成" do
    setup do
      # github_org を固定（issue #45 で既定を廃止したため、削除コマンドの owner を
      # 実 config に依存させず決定的にする）。この describe に限定して汚染を避ける。
      Application.put_env(:registry_manager, :cli_overrides, %{github_org: "smkwlab"})
      on_exit(fn -> Application.delete_env(:registry_manager, :cli_overrides) end)
      :ok
    end

    test "generates correct gh command for repository deletion without deprecated --confirm flag" do
      repo_name = "k21rs001-sotsuron"
      expected_command = "gh repo delete smkwlab/k21rs001-sotsuron"

      assert {:ok, ^expected_command} = Repository.build_github_deletion_command(repo_name)
    end

    test "handles different repository name formats" do
      test_cases = [
        {"k21rs001-sotsuron", "gh repo delete smkwlab/k21rs001-sotsuron"},
        {"k22rs999-wr", "gh repo delete smkwlab/k22rs999-wr"},
        {"test-repo", "gh repo delete smkwlab/test-repo"}
      ]

      Enum.each(test_cases, fn {repo_name, expected} ->
        assert {:ok, ^expected} = Repository.build_github_deletion_command(repo_name)
      end)
    end
  end

  describe "build_github_deletion_command/1 - github_org 未設定時のエラー (issue #45)" do
    setup do
      # github_org も registry_repo も無い状態を、存在しない config を指すことで
      # 決定的に作る（実 config / cli_overrides への依存を断つ）。owner 導出が働かず
      # require_github_org が明示エラーを返すことを検証する。
      Application.put_env(
        :registry_manager,
        :config_path,
        "/nonexistent/registry-manager-#{System.unique_integer([:positive])}.yml"
      )

      Application.delete_env(:registry_manager, :cli_overrides)

      on_exit(fn -> Application.delete_env(:registry_manager, :config_path) end)
      :ok
    end

    test "returns an explicit error when github_org is not configured" do
      assert {:error, message} = Repository.build_github_deletion_command("some-repo")
      assert message =~ "github_org is not configured"
    end
  end
end
