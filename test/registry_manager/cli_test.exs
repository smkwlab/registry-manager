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
      assert {:validate, nil, []} = result
    end

    test "parses cache-status command (hyphenated form)" do
      result = CLI.parse_command(["cache-status"], [])
      assert {:cache, ["status"], []} = result
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
    test "deletion options with force and delete-github-repo" do
      args = ["remove", "repo-name", "--delete-github-repo", "--force"]
      result = CLI.parse_args(args)

      assert {:remove, "repo-name", opts} = result
      assert opts[:delete_github_repo] == true
      assert opts[:force] == true
    end
  end

  describe "edge cases" do
    test "empty arguments default to help" do
      result = CLI.parse_args([])
      assert :help = result
    end

    test "handles mixed valid and invalid options" do
      # Valid options are parsed, invalid ones are ignored by OptionParser
      result = CLI.parse_args(["list", "--format", "json", "--invalid-option"])
      assert {:list, nil, opts} = result
      assert opts[:format] == "json"
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
        "registry-manager - thesis-student-registry 管理ツール",
        "使用方法:",
        "add <repo_name> <student_id> <repo_type>"
      ])
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
      parsed_command = {:validate, nil, []}

      result = run_cli_process(parsed_command)

      # Validate コマンドは正常実行される
      assert_success_exit(result)
      # コマンドの出力があることを確認
      output = Application.get_env(:registry_manager, :test_output, "")
      assert is_binary(output)
    end

    test "update command with invalid data" do
      parsed_command = {:update, {"non-existent-repo", "status", "invalid-status"}, []}

      result = run_cli_process(parsed_command)

      # 無効なデータの更新はエラー
      assert_error_exit(result)
      assert_output_contains("❌ エラー:")
    end
  end
end
