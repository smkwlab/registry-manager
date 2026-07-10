defmodule RegistryManager.RepositoryPersistenceTest do
  use ExUnit.Case, async: false

  alias RegistryManager.Repository
  alias RegistryManager.Test.GitHubAPIMock

  @moduledoc """
  DataStore と統合された Repository の永続化系公開関数のテスト。

  GitHubAPIMock（テストモードで自動有効化）が固定のレジストリデータ
  （k21rs001-sotsuron / k21rs002-wr / k21rs003-wr）を返し、更新系は常に
  成功を返す。CSV 参照は test/fixtures/test_students.csv を使用する。
  """

  setup do
    Application.put_env(:registry_manager, :env, :test)

    # github_org を固定（issue #45 で既定を廃止したため、リポジトリ owner への
    # フォールバック解決を実 config に依存させず決定的にする）
    Application.put_env(:registry_manager, :cli_overrides, %{github_org: "smkwlab"})
    GitHubAPIMock.reset_mock_responses()

    on_exit(fn ->
      Application.delete_env(:registry_manager, :cli_overrides)
      GitHubAPIMock.reset_mock_responses()
    end)

    :ok
  end

  describe "add/4 (non dry-run, persisted via DataStore)" do
    test "adds a repository using github_username supplied in opts" do
      assert {:ok, message} =
               Repository.add("k21rs001-sotsuron", "k21rs001", "sotsuron",
                 github_username: "taro-yamada"
               )

      assert message =~ "Repository updated successfully"
    end

    test "resolves github_username from CSV when not supplied" do
      # student k21rs002 maps to hanako-suzuki in the fixture CSV
      assert {:ok, message} = Repository.add("k21rs002-wr", "k21rs002", "wr", [])
      assert message =~ "Repository updated successfully"
    end

    test "rejects invalid student_id before touching the data store" do
      assert {:error, reason} = Repository.add("bad-repo", "invalid", "wr", [])
      assert reason =~ "不正な学生ID形式"
    end
  end

  describe "add/4 dry-run" do
    test "returns dry-run message without verbose detail" do
      assert {:ok, "[DRY-RUN] リポジトリ情報を追加: k21rs001-sotsuron"} =
               Repository.add("k21rs001-sotsuron", "k21rs001", "sotsuron", dry_run: true)
    end

    test "includes created_at in verbose dry-run message" do
      assert {:ok, message} =
               Repository.add("k21rs001-sotsuron", "k21rs001", "sotsuron",
                 dry_run: true,
                 verbose: true,
                 timestamp: "2025-01-01 00:00:00 UTC"
               )

      assert message =~ "[DRY-RUN]"
      assert message =~ "created_at: 2025-01-01 00:00:00 UTC"
    end
  end

  describe "update/4" do
    test "updates an existing repository field" do
      assert {:ok, message} =
               Repository.update("k21rs001-sotsuron", "protection_status", "protected", [])

      assert message =~ "Repository updated successfully"
    end

    test "returns error for a non-existent repository" do
      assert {:error, reason} =
               Repository.update("does-not-exist", "protection_status", "protected", [])

      assert reason =~ "does-not-exist"
    end

    test "dry-run does not perform the update" do
      assert {:ok, message} =
               Repository.update("k21rs001-sotsuron", "status", "done", dry_run: true)

      assert message =~ "[DRY-RUN]"
      assert message =~ "status = done"
    end
  end

  describe "mark_protected/2" do
    test "marks an existing repository as protected" do
      assert {:ok, message} = Repository.mark_protected("k21rs002-wr", [])
      assert message =~ "Repository updated successfully"
    end

    test "dry-run reports the protection change" do
      assert {:ok, message} = Repository.mark_protected("k21rs002-wr", dry_run: true)
      assert message =~ "protection_status = protected"
    end
  end

  describe "remove/2" do
    test "removes an existing repository" do
      assert {:ok, _result} = Repository.remove("k21rs003-wr", [])
    end

    test "returns error when the repository is absent" do
      assert {:error, reason} = Repository.remove("no-such-repo", [])
      assert reason =~ "not found in registry"
    end

    test "includes gh deletion command when --delete-github-repo is set" do
      assert {:ok, message} =
               Repository.remove("k21rs001-sotsuron", delete_github_repo: true)

      assert message =~ "gh repo delete"
    end

    test "dry-run reports removal without deleting" do
      assert {:ok, message} = Repository.remove("k21rs001-sotsuron", dry_run: true)
      assert message =~ "[DRY-RUN]"
      refute message =~ "GitHubリポジトリ削除コマンド"
    end

    test "dry-run with --delete-github-repo shows the gh command" do
      assert {:ok, message} =
               Repository.remove("k21rs001-sotsuron", dry_run: true, delete_github_repo: true)

      assert message =~ "GitHubリポジトリ削除コマンド"
      assert message =~ "gh repo delete"
    end
  end

  describe "show_status/2" do
    test "shows aggregate statistics when no repository is given" do
      assert {:ok, output} = Repository.show_status(nil)
      assert is_binary(output)
    end

    test "shows details for a specific repository" do
      assert {:ok, output} = Repository.show_status("k21rs001-sotsuron")
      assert output =~ "k21rs001-sotsuron"
    end

    test "returns error for an unknown repository" do
      assert {:error, _reason} = Repository.show_status("unknown-repo")
    end
  end

  describe "list_repositories/2" do
    test "lists all repositories without a filter" do
      assert {:ok, output} = Repository.list_repositories(nil)
      assert output =~ "k21rs001-sotsuron"
    end

    test "filters repositories by type" do
      assert {:ok, output} = Repository.list_repositories("wr")
      assert output =~ "k21rs002-wr"
      refute output =~ "k21rs001-sotsuron"
    end
  end

  describe "get_github_username_for_add/3" do
    test "returns username found in CSV" do
      assert Repository.get_github_username_for_add("k21rs001-sotsuron", "k21rs001", []) ==
               "taro-yamada"
    end

    test "falls back to repository owner when CSV lookup fails" do
      # student k99rs999 is not in the CSV, but the repo resolves via the mock
      assert Repository.get_github_username_for_add("k21rs001-sotsuron", "k99rs999", []) ==
               "taro-yamada"
    end

    test "returns nil when neither CSV nor repository can resolve a username" do
      assert Repository.get_github_username_for_add("no-such-repo", "k99rs999", []) == nil
    end
  end

  describe "get_github_username_from_csv/1" do
    test "returns the github username for a known student" do
      assert {:ok, "taro-yamada"} = Repository.get_github_username_from_csv("k21rs001")
    end

    test "returns error for an unknown student" do
      assert {:error, _reason} = Repository.get_github_username_from_csv("k77rs777")
    end
  end

  describe "get_all_students_from_csv/0" do
    test "parses every valid student row from the fixture CSV" do
      assert {:ok, students} = Repository.get_all_students_from_csv()
      assert is_list(students)

      taro = Enum.find(students, &(&1["student_id"] == "k21rs001"))
      assert taro["name"] == "テスト太郎"
      assert taro["github_username"] == "taro-yamada"
    end
  end
end
