defmodule RegistryManager.CLITest do
  use ExUnit.Case, async: false

  alias RegistryManager.CLI

  # テスト用のヘルパー関数
  defp run_cli_process(parsed_command) do
    CLI.process(parsed_command)
    nil
  catch
    :throw, value -> value
  end

  # テスト結果の検証ヘルパー
  defp assert_success_exit(result) do
    assert result == {:cli_test_exit, 0}
  end

  defp assert_error_exit(result) do
    assert result == {:cli_test_exit, 1}
  end

  defp assert_output_contains(patterns) when is_list(patterns) do
    output = Application.get_env(:registry_manager, :test_output, "")

    Enum.each(patterns, fn pattern ->
      assert output =~ pattern, "Expected output to contain '#{pattern}', but got: #{output}"
    end)
  end

  defp assert_output_contains(pattern) when is_binary(pattern) do
    assert_output_contains([pattern])
  end

  describe "parse_args/1" do
    test "parses help option correctly" do
      assert CLI.parse_args(["-h"]) == :help
      assert CLI.parse_args(["--help"]) == :help
    end

    test "parses command with no options" do
      result = CLI.parse_args(["add", "repo-name", "k21rs001", "sotsuron"])
      assert {:add_explicit, {"repo-name", "k21rs001", "sotsuron"}, []} = result
    end

    test "parses command with options" do
      result = CLI.parse_args(["add", "repo-name", "k21rs001", "sotsuron", "--dry-run", "-v"])
      assert {:add_explicit, {"repo-name", "k21rs001", "sotsuron"}, opts} = result
      assert opts[:dry_run] == true
      assert opts[:verbose] == true
    end

    test "parses -p shortcut for --show-protection" do
      result = CLI.parse_args(["list", "-p"])
      assert {:list, nil, opts} = result
      assert opts[:show_protection] == true
    end

    test "parses -p shortcut with other options" do
      result = CLI.parse_args(["list", "-p", "-l", "--format", "csv"])
      assert {:list, nil, opts} = result
      assert opts[:show_protection] == true
      assert opts[:long] == true
      assert opts[:format] == "csv"
    end
  end

  describe "parse_command/2" do
    test "parses add command with new format" do
      result = CLI.parse_command(["add", "repo-name", "k21rs001", "sotsuron"], [])
      assert {:add_explicit, {"repo-name", "k21rs001", "sotsuron"}, []} = result
    end

    test "rejects add command with old format" do
      result = CLI.parse_command(["add", "repo", "k21rs001", "sotsuron", "active", "thesis"], [])
      assert {:error, _message} = result
    end

    test "parses update command" do
      result = CLI.parse_command(["update", "repo-name", "status", "completed"], [])
      assert {:update, {"repo-name", "status", "completed"}, []} = result
    end

    test "parses remove command" do
      result = CLI.parse_command(["remove", "repo-name"], dry_run: true)
      assert {:remove, "repo-name", [dry_run: true]} = result
    end

    test "parses rm command (alias for remove)" do
      result = CLI.parse_command(["rm", "repo-name"], dry_run: true)
      assert {:remove, "repo-name", [dry_run: true]} = result
    end

    test "parses rm command with options" do
      result = CLI.parse_command(["rm", "test-repo"], force: true, delete_github_repo: true)
      assert {:remove, "test-repo", opts} = result
      assert opts[:force] == true
      assert opts[:delete_github_repo] == true
    end

    test "parses protect command" do
      result = CLI.parse_command(["protect", "repo-name"], [])
      assert {:protect, "repo-name", []} = result
    end

    test "parses list command" do
      result = CLI.parse_command(["list"], [])
      assert {:list, nil, []} = result
    end

    test "parses list command with filter" do
      result = CLI.parse_command(["list", "active"], [])
      assert {:list, "active", []} = result
    end

    test "parses ls command (alias for list)" do
      result = CLI.parse_command(["ls"], [])
      assert {:list, nil, []} = result
    end

    test "parses ls command with filter" do
      result = CLI.parse_command(["ls", "sotsuron"], [])
      assert {:list, "sotsuron", []} = result
    end

    test "parses validate command" do
      result = CLI.parse_command(["validate"], [])
      assert {:validate, [], []} = result
    end

    test "parses validate command with a repository name" do
      result = CLI.parse_command(["validate", "k21rs001-sotsuron"], [])
      assert {:validate, ["k21rs001-sotsuron"], []} = result
    end

    test "returns help for validate with too many arguments" do
      assert :help = CLI.parse_command(["validate", "a", "b"], [])
    end

    test "parses cache subcommand with a repository name" do
      result = CLI.parse_command(["cache", "status", "k21rs001-sotsuron"], [])
      assert {:cache, ["status", "k21rs001-sotsuron"], []} = result
    end

    test "parses cache-status command (hyphenated form)" do
      result = CLI.parse_command(["cache-status"], [])
      assert {:cache, ["status"], []} = result
    end

    test "parses cache-status command with a repository name" do
      result = CLI.parse_command(["cache-status", "k21rs001-sotsuron"], [])
      assert {:cache, ["status", "k21rs001-sotsuron"], []} = result
    end

    test "parses cache-clear command (hyphenated form)" do
      result = CLI.parse_command(["cache-clear"], [])
      assert {:cache, ["clear"], []} = result
    end

    test "parses cache-refresh command (hyphenated form)" do
      result = CLI.parse_command(["cache-refresh"], [])
      assert {:cache, ["refresh"], []} = result
    end

    test "returns help for unknown command" do
      result = CLI.parse_command(["unknown"], [])
      assert :help = result
    end

    test "returns help for invalid arguments" do
      assert {:add_auto, "repo-name", []} = CLI.parse_command(["add", "repo-name"], [])
      assert :help = CLI.parse_command(["update", "repo-name"], [])
      assert :help = CLI.parse_command(["remove"], [])
    end
  end

  describe "option parsing combinations" do
    test "deletion options with delete-github-repo" do
      args = ["remove", "repo-name", "--delete-github-repo"]
      result = CLI.parse_args(args)

      assert {:remove, "repo-name", opts} = result
      assert opts[:delete_github_repo] == true
    end
  end

  describe "strict option validation" do
    test "unknown options are rejected instead of silently ignored" do
      assert {:error, message} = CLI.parse_args(["validate", "--fix"])
      assert message =~ "--fix"
    end

    test "options from another command are rejected" do
      assert {:error, message} = CLI.parse_args(["add", "repo-name", "--format", "json"])
      assert message =~ "--format"
    end

    test "force is not accepted by remove (nothing reads it)" do
      assert {:error, message} = CLI.parse_args(["remove", "repo-name", "--force"])
      assert message =~ "--force"
    end

    test "enum values are validated at parse time" do
      assert {:error, message} = CLI.parse_args(["list", "--type", "bogus"])
      assert message =~ "bogus"
    end

    test "propagate-workflow --type is enum-validated" do
      assert {:error, message} =
               CLI.parse_args(["propagate-workflow", "--all", "--type", "bogus"])

      assert message =~ "bogus"
    end

    test "command --help returns command-scoped help" do
      assert {:help_command, "pr-status"} = CLI.parse_args(["pr-status", "--help"])
      assert :help = CLI.parse_args(["--help"])
    end
  end

  describe "unified sort vocabulary" do
    test "list accepts --sort time with reverse" do
      assert {:list, nil, opts} = CLI.parse_args(["list", "--sort", "time", "-r"])
      assert opts[:sort] == "time"
      assert opts[:reverse] == true
    end

    test "-t is shorthand for --sort time" do
      assert {:list, nil, opts} = CLI.parse_args(["list", "-t"])
      assert opts[:sort] == "time"
      refute Keyword.has_key?(opts, :t)
    end

    test "explicit --sort wins over -t" do
      assert {:list, nil, opts} = CLI.parse_args(["list", "-t", "--sort", "name"])
      assert opts[:sort] == "name"
    end

    test "--sort-by-time is removed" do
      assert {:error, message} = CLI.parse_args(["list", "--sort-by-time"])
      assert message =~ "--sort-by-time"
    end

    test "list rejects pr-status sort keys" do
      assert {:error, message} = CLI.parse_args(["list", "--sort", "updated"])
      assert message =~ "updated"
    end

    test "pr-status sort surface is unchanged" do
      assert {:pr_status, nil, opts} = CLI.parse_args(["pr-status", "--sort", "updated", "-r"])
      assert opts[:sort] == "updated"
    end
  end

  describe "config override flags (issue #38)" do
    setup do
      on_exit(fn ->
        Application.delete_env(:registry_manager, :cli_overrides)
        Application.delete_env(:registry_manager, :config_path)
      end)

      :ok
    end

    test "--registry-repo sets the cli override for any command" do
      assert {:list, nil, _opts} = CLI.parse_args(["list", "--registry-repo", "acme/registry"])

      assert Application.get_env(:registry_manager, :cli_overrides) == %{
               registry_repo: "acme/registry"
             }
    end

    test "invalid --registry-repo fails at parse time" do
      assert {:error, message} = CLI.parse_args(["list", "--registry-repo", "not-a-repo"])
      assert message =~ "owner/repo"
      assert Application.get_env(:registry_manager, :cli_overrides) == nil
    end

    test "-c sets the config path override" do
      assert {:validate, [], _opts} = CLI.parse_args(["validate", "-c", "/tmp/alt-config.yml"])
      assert Application.get_env(:registry_manager, :config_path) == "/tmp/alt-config.yml"
    end

    test "--org is a global override" do
      assert {:pr_status, nil, _opts} = CLI.parse_args(["pr-status", "--org", "acme"])
      assert Application.get_env(:registry_manager, :cli_overrides) == %{github_org: "acme"}
    end

    test "no override flags leaves the application env untouched" do
      assert {:list, nil, _opts} = CLI.parse_args(["list"])
      assert Application.get_env(:registry_manager, :cli_overrides) == nil
      assert Application.get_env(:registry_manager, :config_path) == nil
    end

    test "a run without override flags clears stale overrides" do
      Application.put_env(:registry_manager, :cli_overrides, %{registry_repo: "stale/repo"})
      Application.put_env(:registry_manager, :config_path, "/stale/path.yml")

      assert {:list, nil, _opts} = CLI.parse_args(["list"])

      assert Application.get_env(:registry_manager, :cli_overrides) == nil
      assert Application.get_env(:registry_manager, :config_path) == nil
    end
  end

  describe "edge cases" do
    test "empty arguments default to help" do
      result = CLI.parse_args([])
      assert :help = result
    end

    test "handles mixed valid and invalid options" do
      # 不明なオプションはサイレント無視せずエラーにする
      result = CLI.parse_args(["list", "--format", "json", "--invalid-option"])
      assert {:error, message} = result
      assert message =~ "--invalid-option"
    end
  end

  describe "process/1 with test mode" do
    setup do
      # テストモードを有効にする
      Application.put_env(:registry_manager, :test_mode, true)
      Application.put_env(:registry_manager, :test_output, "")

      on_exit(fn ->
        Application.delete_env(:registry_manager, :test_mode)
        Application.delete_env(:registry_manager, :test_output)
      end)

      :ok
    end

    test "help command shows usage information" do
      result = run_cli_process(:help)

      assert_success_exit(result)

      assert_output_contains([
        "registry-manager - 学生リポジトリレジストリ管理ツール",
        "使用方法:",
        "add <repo_name> <student_id> <repo_type>"
      ])
    end

    test "help does not mention the removed old-form add command" do
      result = run_cli_process(:help)

      assert_success_exit(result)

      output = Application.get_env(:registry_manager, :test_output, "")
      refute output =~ "<status> [stage]"
      refute output =~ "非推奨"
    end

    test "error handling in add command" do
      # 無効なリポジトリ名でテスト
      parsed_command = {:add_explicit, {"", "k21rs001", "sotsuron"}, []}

      result = run_cli_process(parsed_command)

      assert_error_exit(result)
      assert_output_contains("❌ エラー:")
    end

    test "remove command with non-existent repo" do
      parsed_command = {:remove, "non-existent-repo", []}

      result = run_cli_process(parsed_command)

      # 存在しないリポジトリの削除はエラー
      assert_error_exit(result)
      assert_output_contains("❌ エラー:")
    end

    test "protect command with non-existent repo" do
      parsed_command = {:protect, "non-existent-repo", []}

      result = run_cli_process(parsed_command)

      # 存在しないリポジトリの保護はエラー
      assert_error_exit(result)
      assert_output_contains("❌ エラー:")
    end

    test "list command execution" do
      parsed_command = {:list, nil, []}

      result = run_cli_process(parsed_command)

      # List コマンドは正常実行される
      assert_success_exit(result)
      # コマンドの出力があることを確認
      output = Application.get_env(:registry_manager, :test_output, "")
      assert is_binary(output)
    end

    test "validate command execution" do
      parsed_command = {:validate, [], []}

      result = run_cli_process(parsed_command)

      # Validate コマンドは正常実行され、詳細な検証レポートを出力する
      assert_success_exit(result)
      assert_output_contains("Validation Report")
    end

    test "validate command execution for a single repository" do
      parsed_command = {:validate, ["k21rs001-sotsuron"], []}

      result = run_cli_process(parsed_command)

      assert_success_exit(result)
      assert_output_contains("Validation Report for k21rs001-sotsuron")
    end

    test "update command with invalid data" do
      parsed_command = {:update, {"non-existent-repo", "status", "invalid-status"}, []}

      result = run_cli_process(parsed_command)

      # 無効なデータの更新はエラー
      assert_error_exit(result)
      assert_output_contains("❌ エラー:")
    end
  end

  # GitHubAPIMock が固定レジストリ（k21rs001-sotsuron 等）を返し更新系は成功する
  # ため、成功パスの process_impl 節を網羅できる
  describe "process/1 command dispatch (success paths)" do
    alias RegistryManager.Test.GitHubAPIMock

    setup do
      Application.put_env(:registry_manager, :test_mode, true)
      Application.put_env(:registry_manager, :test_output, "")
      # github_org を固定（issue #45 で既定を廃止したため、CLI 経由の inference で
      # owner/repo の組み立てを実 config に依存させず決定的にする）
      System.put_env("REGISTRY_MANAGER_GITHUB_ORG", "smkwlab")
      GitHubAPIMock.reset_mock_responses()

      on_exit(fn ->
        Application.delete_env(:registry_manager, :test_mode)
        Application.delete_env(:registry_manager, :test_output)
        System.delete_env("REGISTRY_MANAGER_GITHUB_ORG")
        GitHubAPIMock.reset_mock_responses()
      end)

      :ok
    end

    test "add_explicit success prints confirmation and exits 0" do
      result = run_cli_process({:add_explicit, {"k21rs001-sotsuron", "k21rs001", "sotsuron"}, []})
      assert_success_exit(result)
      assert_output_contains("✅")
    end

    test "add_explicit with verbose logs the operation" do
      result =
        run_cli_process(
          {:add_explicit, {"k21rs001-sotsuron", "k21rs001", "sotsuron"}, [verbose: true]}
        )

      assert_success_exit(result)
      assert_output_contains("明示的指定")
    end

    test "add_auto success resolves via inference" do
      # 明示的にモック応答を設定し、他モジュールのモック変更に影響されないようにする
      GitHubAPIMock.set_mock_response(:get_repository_info, fn _repo_name ->
        {:ok, %{"owner" => %{"login" => "taro-yamada"}, "created_at" => "2025-01-01T00:00:00Z"}}
      end)

      result = run_cli_process({:add_auto, "k21rs001-sotsuron", [verbose: true]})
      assert_success_exit(result)
      assert_output_contains("✅")
    end

    test "update success prints confirmation" do
      result =
        run_cli_process(
          {:update, {"k21rs001-sotsuron", "protection_status", "protected"}, [verbose: true]}
        )

      assert_success_exit(result)
      assert_output_contains("✅")
    end

    test "remove success" do
      result = run_cli_process({:remove, "k21rs003-wr", []})
      assert_success_exit(result)
      assert_output_contains("✅")
    end

    test "protect success" do
      result = run_cli_process({:protect, "k21rs002-wr", [verbose: true]})
      assert_success_exit(result)
      assert_output_contains("✅")
    end

    test "migrate status succeeds" do
      result = run_cli_process({:migrate, ["status"], [verbose: true]})
      assert_success_exit(result)
    end

    test "migrate with invalid subcommand errors" do
      result = run_cli_process({:migrate, ["totally-invalid"], []})
      assert_error_exit(result)
      assert_output_contains("❌")
    end

    test "cache status succeeds" do
      result = run_cli_process({:cache, ["status"], [verbose: true]})
      assert_success_exit(result)
    end

    test "edit success adds an owner" do
      result = run_cli_process({:edit, "k21rs001-sotsuron", [add_owner: "extra-owner"]})
      assert_success_exit(result)
      assert_output_contains("Successfully added")
    end

    test "edit without an action errors" do
      result = run_cli_process({:edit, "k21rs001-sotsuron", [verbose: true]})
      assert_error_exit(result)
      assert_output_contains("❌")
    end

    test "infer_student_id errors when repository already has a student_id" do
      result = run_cli_process({:infer_student_id, "k21rs001-sotsuron", [verbose: true]})
      assert_error_exit(result)
      assert_output_contains("❌")
    end
  end
end
