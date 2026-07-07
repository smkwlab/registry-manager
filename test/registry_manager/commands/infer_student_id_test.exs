defmodule RegistryManager.Commands.InferStudentIdTest do
  use ExUnit.Case, async: true

  alias RegistryManager.Commands.InferStudentId

  describe "infer_student_id/2" do
    # test_mode はグローバル Application env ではなく opts 経由で渡す（async レース回避）

    test "successfully infers and sets student_id from CSV via github_username" do
      # Setup test data - use unique test repository name
      test_repositories = %{
        "test-repo-123" => %{
          "repository_type" => "wr",
          "github_username" => "test-github-user",
          "created_at" => "2025-07-08T12:00:00Z",
          "registry_updated_at" => "2025-07-10T12:00:00Z"
        }
      }

      test_csv_data = [
        ["氏名", "よみ", "学籍番号", "所属", "学年", "学科", "教員", "GitHub ID"],
        ["テスト太郎", "てすとたろう", "k99rs999", "情報科学部", "3", "情報科学科", "田中", "test-github-user"]
      ]

      test_params = [
        repositories: test_repositories,
        csv_data: test_csv_data
      ]

      # Execute（test_mode は opts 経由で渡し、実更新をスキップさせる）
      result = InferStudentId.run(["test-repo-123"], [test_mode: true], test_params)

      # Verify
      assert {:ok, message} = result

      assert String.contains?(
               message,
               "Student ID 'k99rs999' has been set for repository 'test-repo-123'"
             )
    end

    test "fails when repository not found" do
      test_params = [
        repositories: %{},
        csv_data: []
      ]

      result = InferStudentId.run(["non-existent-repo"], [], test_params)

      assert {:error, "Repository 'non-existent-repo' not found in registry"} = result
    end

    test "fails when github_username not set in repository" do
      test_repositories = %{
        "repo-without-github" => %{
          "repository_type" => "wr",
          "created_at" => "2025-07-08T12:00:00Z",
          "registry_updated_at" => "2025-07-10T12:00:00Z"
        }
      }

      test_params = [
        repositories: test_repositories,
        csv_data: []
      ]

      result = InferStudentId.run(["repo-without-github"], [], test_params)

      assert {:error, "Repository 'repo-without-github' does not have github_username set"} =
               result
    end

    test "fails when github_username not found in CSV" do
      test_repositories = %{
        "unknown-user-repo" => %{
          "repository_type" => "wr",
          "github_username" => "unknown_user",
          "created_at" => "2025-07-08T12:00:00Z",
          "registry_updated_at" => "2025-07-10T12:00:00Z"
        }
      }

      test_csv_data = [
        ["氏名", "よみ", "学籍番号", "所属", "学年", "学科", "教員", "GitHub ID"],
        ["山田太郎", "やまだたろう", "k91rs044", "情報科学部", "3", "情報科学科", "田中", "mockuser3"]
      ]

      test_params = [
        repositories: test_repositories,
        csv_data: test_csv_data
      ]

      result = InferStudentId.run(["unknown-user-repo"], [], test_params)

      assert {:error, "GitHub username 'unknown_user' not found in CSV file"} = result
    end

    test "fails when student_id already set in repository" do
      test_repositories = %{
        "already-has-student-id" => %{
          "student_id" => "k21rs001",
          "repository_type" => "wr",
          "github_username" => "mockuser3",
          "created_at" => "2025-07-08T12:00:00Z",
          "registry_updated_at" => "2025-07-10T12:00:00Z"
        }
      }

      test_params = [
        repositories: test_repositories,
        csv_data: []
      ]

      result = InferStudentId.run(["already-has-student-id"], [], test_params)

      assert {:error, "Repository 'already-has-student-id' already has student_id 'k21rs001' set"} =
               result
    end

    test "handles dry run mode" do
      test_repositories = %{
        "91rs044-wr" => %{
          "repository_type" => "wr",
          "github_username" => "mockuser3",
          "created_at" => "2025-07-08T12:00:00Z",
          "registry_updated_at" => "2025-07-10T12:00:00Z"
        }
      }

      test_csv_data = [
        ["氏名", "よみ", "学籍番号", "所属", "学年", "学科", "教員", "GitHub ID"],
        ["山田太郎", "やまだたろう", "k91rs044", "情報科学部", "3", "情報科学科", "田中", "mockuser3"]
      ]

      test_params = [
        repositories: test_repositories,
        csv_data: test_csv_data
      ]

      result = InferStudentId.run(["91rs044-wr"], [dry_run: true], test_params)

      assert {:ok, message} = result
      assert String.contains?(message, "[DRY-RUN]")

      assert String.contains?(
               message,
               "Would set student_id 'k91rs044' for repository '91rs044-wr'"
             )
    end
  end

  describe "edge cases" do
    # このブロックの各テストは update 経路に到達しない（username 抽出/状態検証で
    # エラーになる）ため test_mode は不要。グローバル :test_mode は設定しない（async レース回避）

    test "treats an empty github_username as missing" do
      test_repositories = %{
        "empty-github-repo" => %{
          "repository_type" => "wr",
          "github_username" => "",
          "created_at" => "2025-07-08T12:00:00Z"
        }
      }

      test_params = [repositories: test_repositories, csv_data: []]

      assert {:error, message} = InferStudentId.run(["empty-github-repo"], [], test_params)
      assert message =~ "does not have github_username set"
    end

    test "loads repositories from the GitHub API mock when none are supplied" do
      # :repositories を渡さないことで get_repositories の API 経路（モック）を通す。
      # モックの k21rs002-wr は student_id を持つため、状態検証でエラーになる。
      assert {:error, message} = InferStudentId.run(["k21rs002-wr"], [], csv_data: [])
      assert message =~ "already has student_id"
    end
  end

  describe "parse_args/1" do
    test "parses valid repository name" do
      assert {:ok, {"91rs044-wr", []}} = InferStudentId.parse_args(["91rs044-wr"])
    end

    test "fails with no arguments" do
      assert {:error, "Repository name is required"} = InferStudentId.parse_args([])
    end

    test "fails with too many arguments" do
      assert {:error, "Too many arguments. Usage: infer-student-id <repository_name>"} =
               InferStudentId.parse_args(["repo1", "repo2"])
    end
  end
end
