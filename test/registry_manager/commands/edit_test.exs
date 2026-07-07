defmodule RegistryManager.Commands.EditTest do
  use ExUnit.Case, async: false

  alias RegistryManager.Commands.Edit
  alias RegistryManager.Test.GitHubAPIMock

  setup do
    # テスト用環境変数を設定
    original_env = System.get_env("MIX_ENV")
    System.put_env("MIX_ENV", "test")

    on_exit(fn ->
      if original_env do
        System.put_env("MIX_ENV", original_env)
      else
        System.delete_env("MIX_ENV")
      end
    end)

    # 基本的なレジストリデータをセットアップ
    initial_data = %{
      "test-repo-single" => %{
        "student_id" => "k21rs001",
        "repository_type" => "wr",
        "github_username" => "user1",
        "created_at" => "2025-07-01T00:00:00Z",
        "registry_updated_at" => "2025-07-01T00:00:00Z"
      },
      "test-repo-array" => %{
        "student_id" => "k21rs002",
        "repository_type" => "wr",
        "github_username" => ["user2", "user3"],
        "created_at" => "2025-07-01T00:00:00Z",
        "registry_updated_at" => "2025-07-01T00:00:00Z"
      },
      "test-repo-empty" => %{
        "student_id" => "k21rs003",
        "repository_type" => "wr",
        "created_at" => "2025-07-01T00:00:00Z",
        "registry_updated_at" => "2025-07-01T00:00:00Z"
      }
    }

    # 更新されたデータを保持するためのAgent
    {:ok, agent} = Agent.start_link(fn -> initial_data end)

    # GitHubAPIMockにデータを設定
    GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
      data = Agent.get(agent, & &1)
      {:ok, {data, "test-sha"}}
    end)

    GitHubAPIMock.set_mock_response(:update_repositories_json, fn new_data, _sha, _msg ->
      Agent.update(agent, fn _ -> new_data end)
      {:ok, "Repository updated successfully"}
    end)

    # テスト終了時のクリーンアップ
    on_exit(fn ->
      # Process.alive? チェックだけでは TOCTOU レースが残る（リンクされた agent が
      # チェック通過後・stop 実行前に終了し得る）。stop の :exit を捕捉して吸収する。
      try do
        Agent.stop(agent)
      catch
        :exit, _ -> :ok
      end

      # モックをクリア
      GitHubAPIMock.clear_mock_responses()
    end)

    # テスト用パラメータを返す
    {:ok,
     %{
       agent: agent
     }}
  end

  describe "add_owner option" do
    test "adds owner to repository with no github_username", %{agent: agent} do
      result = Edit.run(["test-repo-empty"], add_owner: "newuser")

      assert {:ok, message} = result
      assert message =~ "Successfully added 'newuser' as owner"

      # 更新されたデータを確認
      updated_data = Agent.get(agent, & &1)
      assert updated_data["test-repo-empty"]["github_username"] == ["newuser"]
    end

    test "adds owner to repository with single username", %{agent: agent} do
      result = Edit.run(["test-repo-single"], add_owner: "newuser")

      assert {:ok, message} = result
      assert message =~ "Successfully added 'newuser' as owner"

      updated_data = Agent.get(agent, & &1)
      assert updated_data["test-repo-single"]["github_username"] == ["user1", "newuser"]
    end

    test "adds owner to repository with array of usernames", %{agent: agent} do
      result = Edit.run(["test-repo-array"], add_owner: "user4")

      assert {:ok, message} = result
      assert message =~ "Successfully added 'user4' as owner"

      updated_data = Agent.get(agent, & &1)
      assert updated_data["test-repo-array"]["github_username"] == ["user2", "user3", "user4"]
    end

    test "does not add duplicate owner", %{agent: agent} do
      result = Edit.run(["test-repo-array"], add_owner: "user2")

      assert {:ok, _message} = result

      updated_data = Agent.get(agent, & &1)
      assert updated_data["test-repo-array"]["github_username"] == ["user2", "user3"]
    end

    test "handles empty username", %{agent: agent} do
      result = Edit.run(["test-repo-single"], add_owner: "")

      assert {:ok, _message} = result

      updated_data = Agent.get(agent, & &1)
      assert updated_data["test-repo-single"]["github_username"] == "user1"
    end
  end

  describe "remove_owner option" do
    test "removes owner from repository with array", %{agent: agent} do
      result = Edit.run(["test-repo-array"], remove_owner: "user2")

      assert {:ok, message} = result
      assert message =~ "Successfully removed 'user2' from owners"

      updated_data = Agent.get(agent, & &1)
      assert updated_data["test-repo-array"]["github_username"] == ["user3"]
    end

    test "removes last owner and deletes field", %{agent: agent} do
      result = Edit.run(["test-repo-single"], remove_owner: "user1")

      assert {:ok, message} = result
      assert message =~ "Successfully removed 'user1' from owners"

      updated_data = Agent.get(agent, & &1)
      refute Map.has_key?(updated_data["test-repo-single"], "github_username")
    end

    test "handles removing non-existent owner", %{agent: agent} do
      result = Edit.run(["test-repo-array"], remove_owner: "nonexistent")

      assert {:ok, _message} = result

      updated_data = Agent.get(agent, & &1)
      assert updated_data["test-repo-array"]["github_username"] == ["user2", "user3"]
    end
  end

  describe "set_owners option" do
    test "sets multiple owners", %{agent: agent} do
      result = Edit.run(["test-repo-single"], set_owners: "user5,user6,user7")

      assert {:ok, message} = result
      assert message =~ "Successfully set owners"
      assert message =~ "user5, user6, user7"

      updated_data = Agent.get(agent, & &1)
      assert updated_data["test-repo-single"]["github_username"] == ["user5", "user6", "user7"]
    end

    test "removes duplicates when setting owners", %{agent: agent} do
      result = Edit.run(["test-repo-single"], set_owners: "user8,user9,user8")

      assert {:ok, _message} = result

      updated_data = Agent.get(agent, & &1)
      assert updated_data["test-repo-single"]["github_username"] == ["user8", "user9"]
    end

    test "removes field when setting empty owners", %{agent: agent} do
      result = Edit.run(["test-repo-array"], set_owners: "")

      assert {:ok, _message} = result

      updated_data = Agent.get(agent, & &1)
      refute Map.has_key?(updated_data["test-repo-array"], "github_username")
    end

    test "handles whitespace in comma-separated list", %{agent: agent} do
      result = Edit.run(["test-repo-single"], set_owners: "user10, user11 , user12")

      assert {:ok, _message} = result

      updated_data = Agent.get(agent, & &1)
      assert updated_data["test-repo-single"]["github_username"] == ["user10", "user11", "user12"]
    end
  end

  describe "error handling" do
    test "returns error when no action specified" do
      result = Edit.run(["test-repo-single"], [])

      assert {:error, message} = result
      assert message =~ "No edit action specified"
    end

    test "returns error when multiple actions specified" do
      result = Edit.run(["test-repo-single"], add_owner: "user1", remove_owner: "user2")

      assert {:error, message} = result
      assert message =~ "Only one edit action can be specified"
    end

    test "returns error when repository not found" do
      result = Edit.run(["non-existent-repo"], add_owner: "user1")

      assert {:error, message} = result
      assert message =~ "Repository 'non-existent-repo' not found"
    end

    test "returns error when no repository name provided" do
      result = Edit.run([], add_owner: "user1")

      assert {:error, message} = result
      assert message =~ "Repository name is required"
    end

    test "returns error with invalid arguments" do
      result = Edit.run(["repo1", "repo2"], add_owner: "user1")

      assert {:error, message} = result
      assert message =~ "Invalid arguments"
    end
  end
end
