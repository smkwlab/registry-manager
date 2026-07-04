defmodule RegistryManager.MultipleOwnersIntegrationTest do
  use ExUnit.Case, async: false

  alias RegistryManager.Commands.List

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

    # 複数オーナーを持つリポジトリデータ
    initial_data = %{
      "k93rs101-wr" => %{
        "student_id" => "k93rs101",
        "repository_type" => "wr",
        "github_username" => ["k93RS101", "mockuser101"],
        "created_at" => "2025-07-01T00:00:00Z",
        "registry_updated_at" => "2025-07-01T00:00:00Z"
      },
      "k21rs001-sotsuron" => %{
        "student_id" => "k21rs001",
        "repository_type" => "sotsuron",
        "github_username" => "single-user",
        "created_at" => "2025-07-01T00:00:00Z",
        "registry_updated_at" => "2025-07-01T00:00:00Z"
      }
    }

    # テスト用パラメータを返す（Agentの競合を避けるため、テストパラメータのみ使用）
    {:ok,
     %{
       test_data: initial_data
     }}
  end

  describe "multiple owners with list -o option" do
    test "list command works with multiple owners data", %{test_data: test_data} do
      # 複数オーナーを持つリポジトリのリストが正常に動作することを確認
      test_repos = %{
        "k93rs101-wr" => test_data["k93rs101-wr"]
      }

      result = List.run([], [long: true], repositories: test_repos, csv_data: [])

      assert {:ok, output} = result
      assert output =~ "k93rs101-wr"
      assert output =~ "k93rs101"
      # 複数オーナーが正しく表示される
      assert output =~ "k93RS101, mockuser101"
    end

    test "list with owner activity works with multiple owners", %{test_data: test_data} do
      # オーナーアクティビティオプションが複数オーナーで動作することを確認
      test_repos = %{
        "k93rs101-wr" => test_data["k93rs101-wr"]
      }

      # モックアクティビティデータ
      test_activity = %{
        "k93rs101-wr" => %{
          "last_activity" => "2025-07-08T12:00:00Z",
          "owner_last_activity" => "2025-07-10T15:30:00Z"
        }
      }

      result =
        List.run([], [long: true, owner_activity: true],
          repositories: test_repos,
          activity_data: test_activity,
          csv_data: []
        )

      assert {:ok, output} = result
      assert output =~ "k93rs101-wr"
      # オーナーアクティビティの日付が含まれている
      assert output =~ "2025-07-11"
    end
  end

  describe "compatibility module integration" do
    test "compatibility module works correctly" do
      # Compatibilityモジュールが正しく動作することを確認
      single_username_data = %{"github_username" => "single-user"}
      array_username_data = %{"github_username" => ["user1", "user2"]}

      # 正規化テスト
      assert RegistryManager.Repository.Compatibility.normalize_github_username("single-user") ==
               ["single-user"]

      assert RegistryManager.Repository.Compatibility.normalize_github_username([
               "user1",
               "user2"
             ]) == ["user1", "user2"]

      # データ取得テスト
      assert RegistryManager.Repository.Compatibility.get_all_github_usernames(
               single_username_data
             ) == ["single-user"]

      assert RegistryManager.Repository.Compatibility.get_all_github_usernames(
               array_username_data
             ) == ["user1", "user2"]
    end
  end
end
