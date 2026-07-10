defmodule RegistryManager.CLIAddInferenceTest do
  use ExUnit.Case, async: false

  alias RegistryManager.CLI
  alias RegistryManager.Test.GitHubAPIMock

  describe "parse_add_command/2 with inference" do
    test "parses add command with single repository name" do
      assert {:add_auto, "k21rs001-sotsuron", []} =
               CLI.parse_command(["add", "k21rs001-sotsuron"], [])
    end

    test "parses add command with single repository name and options" do
      opts = [verbose: true, dry_run: true]
      assert {:add_auto, "k21rs001-wr", ^opts} = CLI.parse_command(["add", "k21rs001-wr"], opts)
    end

    test "still supports traditional three-argument format" do
      assert {:add_explicit, {"k21rs001-sotsuron", "k21rs001", "sotsuron"}, []} =
               CLI.parse_command(["add", "k21rs001-sotsuron", "k21rs001", "sotsuron"], [])
    end

    test "returns help for invalid add command" do
      assert :help = CLI.parse_command(["add"], [])
      # Commands with 4+ arguments trigger old format error message
      assert {:error, _} =
               CLI.parse_command(["add", "repo", "extra", "params", "too", "many"], [])
    end
  end

  describe "process/1 with add_auto" do
    setup do
      Application.put_env(:registry_manager, :test_mode, true)
      Application.put_env(:registry_manager, :test_output, "")
      Application.put_env(:registry_manager, :env, :test)
      Application.put_env(:registry_manager, :use_github_mock, true)

      # github_org を固定（issue #45 で既定を廃止したため、CLI 経由の inference で
      # owner/repo の組み立てを実 config に依存させず決定的にする）。CLI が
      # cli_overrides を再設定するため env var 側で固定する
      System.put_env("REGISTRY_MANAGER_GITHUB_ORG", "smkwlab")

      # Reset mock responses for clean state
      GitHubAPIMock.reset_mock_responses()

      on_exit(fn ->
        Application.delete_env(:registry_manager, :test_mode)
        Application.delete_env(:registry_manager, :test_output)
        Application.put_env(:registry_manager, :env, :test)
        Application.delete_env(:registry_manager, :use_github_mock)
        System.delete_env("REGISTRY_MANAGER_GITHUB_ORG")
        GitHubAPIMock.reset_mock_responses()
      end)

      :ok
    end

    test "successful add with inference" do
      # Setup mock responses
      GitHubAPIMock.set_mock_response(:get_repository_info, fn _repo_name ->
        {:ok,
         %{
           "owner" => %{"login" => "taro-yamada"},
           "created_at" => "2025-01-01T00:00:00Z"
         }}
      end)

      GitHubAPIMock.set_mock_response(
        :update_repositories_json,
        fn _new_data, _sha, _message ->
          {:ok, "Success"}
        end
      )

      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {%{}, "mock_sha"}}
      end)

      # Execute
      assert catch_throw(CLI.process({:add_auto, "k21rs001-sotsuron", []})) == {:cli_test_exit, 0}

      output = Application.get_env(:registry_manager, :test_output)
      assert output =~ "✅"
    end

    test "shows verbose output when requested" do
      # Setup mock responses
      GitHubAPIMock.set_mock_response(:get_repository_info, fn _repo_name ->
        {:ok,
         %{
           "owner" => %{"login" => "taro-yamada"},
           "created_at" => "2025-01-01T00:00:00Z"
         }}
      end)

      GitHubAPIMock.set_mock_response(
        :update_repositories_json,
        fn _new_data, _sha, _message ->
          {:ok, "Success"}
        end
      )

      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {%{}, "mock_sha"}}
      end)

      # Execute with verbose
      assert catch_throw(CLI.process({:add_auto, "k21rs001-sotsuron", [verbose: true]})) ==
               {:cli_test_exit, 0}

      output = Application.get_env(:registry_manager, :test_output)
      assert output =~ "GitHub APIから情報を取得中"
    end

    test "shows detailed error with GitHub ID when student ID cannot be determined" do
      # Setup mock responses
      GitHubAPIMock.set_mock_response(:get_repository_info, fn _repo_name ->
        {:ok,
         %{
           "owner" => %{"login" => "unknown-user"},
           "created_at" => "2025-01-01T00:00:00Z"
         }}
      end)

      # Execute
      assert catch_throw(CLI.process({:add_auto, "invalid-repo-wr", []})) == {:cli_test_exit, 1}

      output = Application.get_env(:registry_manager, :test_output)
      assert output =~ "❌ 学生IDを特定できませんでした。"
      assert output =~ "リポジトリ作成者: unknown-user"
      assert output =~ "このGitHub IDがCSVファイルに登録されていません。"
      assert output =~ "リポジトリ名が標準形式（k21rs001-sotsuron）ではありません。"
      assert output =~ "完全な形式を使用してください: add <repo_name> <student_id> <repo_type>"
    end

    test "shows generic error when repository owner cannot be extracted" do
      # Setup mock responses for case where owner cannot be extracted
      GitHubAPIMock.set_mock_response(:get_repository_info, fn _repo_name ->
        {:ok,
         %{
           "created_at" => "2025-01-01T00:00:00Z"
           # Missing owner field
         }}
      end)

      # Execute
      assert catch_throw(CLI.process({:add_auto, "invalid-repo-wr", []})) == {:cli_test_exit, 1}
      output = Application.get_env(:registry_manager, :test_output)
      assert output =~ "❌ エラー: Cannot extract repository owner"
    end

    test "infers 'other' type for unknown repository patterns (Issue #388)" do
      # Setup mock responses
      GitHubAPIMock.set_mock_response(:get_repository_info, fn _repo_name ->
        {:ok,
         %{
           "owner" => %{"login" => "taro-yamada"},
           "created_at" => "2025-01-01T00:00:00Z"
         }}
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn new_data, _sha, _message ->
        # Verify that unknown pattern is classified as "other"
        assert new_data["k21rs001-unknown"]["repository_type"] == "other"
        {:ok, "Success"}
      end)

      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {%{}, "mock_sha"}}
      end)

      # Execute - should succeed with type "other"
      assert catch_throw(CLI.process({:add_auto, "k21rs001-unknown", []})) == {:cli_test_exit, 0}

      output = Application.get_env(:registry_manager, :test_output)
      assert output =~ "✅"
    end

    test "shows generic error for other failures" do
      # Setup mock responses
      GitHubAPIMock.set_mock_response(:get_repository_info, fn _repo_name ->
        {:error, "Network error"}
      end)

      # Execute
      assert catch_throw(CLI.process({:add_auto, "k21rs001-sotsuron", []})) == {:cli_test_exit, 1}

      output = Application.get_env(:registry_manager, :test_output)
      assert output =~ "❌ エラー: Network error"
    end
  end
end
