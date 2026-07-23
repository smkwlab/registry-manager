defmodule RegistryManager.CacheTest do
  use ExUnit.Case

  alias RegistryManager.Cache

  @cache_dir Path.join(System.tmp_dir!(), "registry_manager_test_cache")
  @activity_dir Path.join(@cache_dir, "activity")

  setup do
    # テスト用のキャッシュディレクトリを作成
    File.mkdir_p!(@activity_dir)

    # 既存のキャッシュファイルがあれば削除
    if File.exists?(@cache_dir) do
      File.rm_rf!(@cache_dir)
      File.mkdir_p!(@activity_dir)
    end

    on_exit(fn ->
      # テスト後にクリーンアップ
      if File.exists?(@cache_dir) do
        File.rm_rf!(@cache_dir)
      end
    end)

    {:ok, cache_dir: @cache_dir, activity_dir: @activity_dir}
  end

  describe "get_cache_dir/0" do
    test "returns default cache directory path" do
      cache_dir = Cache.get_cache_dir()
      assert String.ends_with?(cache_dir, ".cache/registry-manager")
    end
  end

  describe "get_activity_cache_path/1" do
    test "returns correct activity cache file path" do
      path = Cache.get_activity_cache_path("k21rs001-sotsuron")
      assert String.ends_with?(path, "activity/k21rs001-sotsuron.json")
    end

    test "handles repository names with special characters" do
      path = Cache.get_activity_cache_path("test-repo_name.with-chars")
      assert String.ends_with?(path, "activity/test-repo_name.with-chars.json")
    end
  end

  describe "put/3" do
    test "stores activity data with TTL", %{cache_dir: cache_dir} do
      activity_data = %{
        "last_activity" => "2025-07-09T09:15:00.000Z",
        "owner_last_activity" => "2025-07-09T08:30:00.000Z",
        "last_commit_sha" => "abc123def456"
      }

      assert :ok = Cache.put("k21rs001-sotsuron", activity_data, cache_dir: cache_dir)

      cache_file = Path.join([cache_dir, "activity", "k21rs001-sotsuron.json"])
      assert File.exists?(cache_file)

      {:ok, content} = File.read(cache_file)
      {:ok, cached_data} = Jason.decode(content)

      assert cached_data["key"] == "k21rs001-sotsuron"
      assert cached_data["data"] == activity_data
      assert is_binary(cached_data["cached_at"])
      assert is_binary(cached_data["expires_at"])
    end

    test "creates cache directory if it doesn't exist" do
      non_existent_dir = Path.join(System.tmp_dir!(), "non_existent_cache")

      activity_data = %{"last_activity" => "2025-07-09T09:15:00.000Z"}

      assert :ok = Cache.put("test-repo", activity_data, cache_dir: non_existent_dir)

      cache_file = Path.join([non_existent_dir, "activity", "test-repo.json"])
      assert File.exists?(cache_file)

      # クリーンアップ
      File.rm_rf!(non_existent_dir)
    end

    test "overwrites existing cache entry" do
      old_data = %{"last_activity" => "2025-07-08T09:15:00.000Z"}
      new_data = %{"last_activity" => "2025-07-09T09:15:00.000Z"}

      assert :ok = Cache.put("test-repo", old_data, cache_dir: @cache_dir)
      assert :ok = Cache.put("test-repo", new_data, cache_dir: @cache_dir)

      {:ok, cached_data} = Cache.get("test-repo", cache_dir: @cache_dir)
      assert cached_data["last_activity"] == "2025-07-09T09:15:00.000Z"
    end
  end

  describe "get/2" do
    test "retrieves valid cached data", %{cache_dir: cache_dir} do
      activity_data = %{
        "last_activity" => "2025-07-09T09:15:00.000Z",
        "owner_last_activity" => "2025-07-09T08:30:00.000Z"
      }

      :ok = Cache.put("k21rs001-sotsuron", activity_data, cache_dir: cache_dir)

      assert {:ok, cached_data} = Cache.get("k21rs001-sotsuron", cache_dir: cache_dir)
      assert cached_data == activity_data
    end

    test "returns cache_miss when file doesn't exist", %{cache_dir: cache_dir} do
      assert {:error, :cache_miss} = Cache.get("non-existent-repo", cache_dir: cache_dir)
    end

    test "returns cache_expired when TTL has passed", %{cache_dir: cache_dir} do
      # TTLを0に設定してすぐに期限切れにする
      activity_data = %{"last_activity" => "2025-07-09T09:15:00.000Z"}

      :ok = Cache.put("test-repo", activity_data, cache_dir: cache_dir, ttl_hours: 0)

      # 少し待ってから取得
      :timer.sleep(10)

      assert {:error, :cache_expired} = Cache.get("test-repo", cache_dir: cache_dir)
    end

    test "returns error when cache file contains invalid JSON", %{cache_dir: cache_dir} do
      cache_file = Path.join([@cache_dir, "activity", "invalid-repo.json"])
      File.mkdir_p!(Path.dirname(cache_file))
      File.write!(cache_file, "invalid json")

      assert {:error, :invalid_cache} = Cache.get("invalid-repo", cache_dir: cache_dir)
    end
  end

  describe "delete/2" do
    test "removes cache file", %{cache_dir: cache_dir} do
      activity_data = %{"last_activity" => "2025-07-09T09:15:00.000Z"}

      :ok = Cache.put("test-repo", activity_data, cache_dir: cache_dir)
      assert {:ok, _} = Cache.get("test-repo", cache_dir: cache_dir)

      assert :ok = Cache.delete("test-repo", cache_dir: cache_dir)
      assert {:error, :cache_miss} = Cache.get("test-repo", cache_dir: cache_dir)
    end

    test "succeeds even if file doesn't exist", %{cache_dir: cache_dir} do
      assert :ok = Cache.delete("non-existent-repo", cache_dir: cache_dir)
    end
  end

  describe "clear/1" do
    test "removes all cache files", %{cache_dir: cache_dir} do
      # 複数のキャッシュを作成
      :ok = Cache.put("repo1", %{"data" => "1"}, cache_dir: cache_dir)
      :ok = Cache.put("repo2", %{"data" => "2"}, cache_dir: cache_dir)
      :ok = Cache.put("repo3", %{"data" => "3"}, cache_dir: cache_dir)

      # すべて存在することを確認
      assert {:ok, _} = Cache.get("repo1", cache_dir: cache_dir)
      assert {:ok, _} = Cache.get("repo2", cache_dir: cache_dir)
      assert {:ok, _} = Cache.get("repo3", cache_dir: cache_dir)

      # クリア実行
      assert :ok = Cache.clear(cache_dir: cache_dir)

      # すべて削除されていることを確認
      assert {:error, :cache_miss} = Cache.get("repo1", cache_dir: cache_dir)
      assert {:error, :cache_miss} = Cache.get("repo2", cache_dir: cache_dir)
      assert {:error, :cache_miss} = Cache.get("repo3", cache_dir: cache_dir)
    end

    test "succeeds even if cache directory doesn't exist" do
      non_existent_dir = Path.join(System.tmp_dir!(), "non_existent_cache")
      assert :ok = Cache.clear(cache_dir: non_existent_dir)
    end
  end

  describe "status/2" do
    test "returns status for existing cache", %{cache_dir: cache_dir} do
      activity_data = %{"last_activity" => "2025-07-09T09:15:00.000Z"}

      :ok = Cache.put("test-repo", activity_data, cache_dir: cache_dir, ttl_hours: 2)

      {:ok, status} = Cache.status("test-repo", cache_dir: cache_dir)

      assert status.repository == "test-repo"
      assert status.exists == true
      assert status.expired == false
      assert is_binary(status.cached_at)
      assert is_binary(status.expires_at)
      assert is_integer(status.size_bytes)
    end

    test "returns status for non-existent cache", %{cache_dir: cache_dir} do
      {:ok, status} = Cache.status("non-existent-repo", cache_dir: cache_dir)

      assert status.repository == "non-existent-repo"
      assert status.exists == false
      assert status.expired == false
      assert is_nil(status.cached_at)
      assert is_nil(status.expires_at)
      assert status.size_bytes == 0
    end

    test "returns status for expired cache", %{cache_dir: cache_dir} do
      activity_data = %{"last_activity" => "2025-07-09T09:15:00.000Z"}

      :ok = Cache.put("test-repo", activity_data, cache_dir: cache_dir, ttl_hours: 0)
      :timer.sleep(10)

      {:ok, status} = Cache.status("test-repo", cache_dir: cache_dir)

      assert status.repository == "test-repo"
      assert status.exists == true
      assert status.expired == true
    end
  end

  describe "refresh/2" do
    test "removes cache to force refresh", %{cache_dir: cache_dir} do
      activity_data = %{"last_activity" => "2025-07-09T09:15:00.000Z"}

      :ok = Cache.put("test-repo", activity_data, cache_dir: cache_dir)
      assert {:ok, _} = Cache.get("test-repo", cache_dir: cache_dir)

      assert :ok = Cache.refresh("test-repo", cache_dir: cache_dir)
      assert {:error, :cache_miss} = Cache.get("test-repo", cache_dir: cache_dir)
    end
  end

  describe "calculate_ttl/1" do
    test "calculates correct expiration time" do
      now = DateTime.utc_now()
      expires_at = Cache.calculate_ttl(now, 2)

      expected = DateTime.add(now, 2 * 60 * 60, :second)

      # 1秒の誤差を許容
      diff = DateTime.diff(expires_at, expected, :second)
      assert abs(diff) <= 1
    end
  end

  describe "expired?/1" do
    test "correctly identifies expired cache" do
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert Cache.expired?(DateTime.to_iso8601(past_time))
    end

    test "correctly identifies valid cache" do
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)
      refute Cache.expired?(DateTime.to_iso8601(future_time))
    end

    test "handles invalid datetime strings" do
      assert Cache.expired?("invalid-datetime")
    end

    test "handles nil values" do
      assert Cache.expired?(nil)
    end
  end

  # Issue #120: pr-status 用キャッシュカテゴリのサポート
  describe "category-based caching" do
    test "get_cache_path/3 returns correct path for pr-status category", %{cache_dir: cache_dir} do
      path = Cache.get_cache_path("test-repo", "pr-status", cache_dir: cache_dir)
      assert String.ends_with?(path, "pr-status/test-repo.json")
    end

    test "get_cache_path/3 returns correct path for activity category (default)", %{
      cache_dir: cache_dir
    } do
      path = Cache.get_cache_path("test-repo", "activity", cache_dir: cache_dir)
      assert String.ends_with?(path, "activity/test-repo.json")
    end

    test "put/3 stores data in specified category", %{cache_dir: cache_dir} do
      pr_data = %{
        "total" => 5,
        "open" => 2,
        "closed" => 3
      }

      assert :ok = Cache.put("test-repo", pr_data, cache_dir: cache_dir, category: "pr-status")

      cache_file = Path.join([cache_dir, "pr-status", "test-repo.json"])
      assert File.exists?(cache_file)

      {:ok, content} = File.read(cache_file)
      {:ok, cached_data} = Jason.decode(content)

      assert cached_data["key"] == "test-repo"
      assert cached_data["data"] == pr_data
    end

    test "get/3 retrieves data from specified category", %{cache_dir: cache_dir} do
      pr_data = %{"total" => 10}

      :ok = Cache.put("test-repo", pr_data, cache_dir: cache_dir, category: "pr-status")

      assert {:ok, retrieved} =
               Cache.get("test-repo", cache_dir: cache_dir, category: "pr-status")

      assert retrieved == pr_data
    end

    test "delete/3 removes data from specified category", %{cache_dir: cache_dir} do
      pr_data = %{"total" => 10}

      :ok = Cache.put("test-repo", pr_data, cache_dir: cache_dir, category: "pr-status")
      assert {:ok, _} = Cache.get("test-repo", cache_dir: cache_dir, category: "pr-status")

      :ok = Cache.delete("test-repo", cache_dir: cache_dir, category: "pr-status")

      assert {:error, :cache_miss} =
               Cache.get("test-repo", cache_dir: cache_dir, category: "pr-status")
    end

    test "clear/2 clears only specified category", %{cache_dir: cache_dir} do
      # activity カテゴリにデータを追加
      :ok = Cache.put("repo1", %{"activity" => true}, cache_dir: cache_dir, category: "activity")
      # pr-status カテゴリにデータを追加
      :ok = Cache.put("repo2", %{"pr" => true}, cache_dir: cache_dir, category: "pr-status")

      # pr-status のみクリア
      :ok = Cache.clear(cache_dir: cache_dir, category: "pr-status")

      # activity は残っている
      assert {:ok, _} = Cache.get("repo1", cache_dir: cache_dir, category: "activity")
      # pr-status は削除されている
      assert {:error, :cache_miss} =
               Cache.get("repo2", cache_dir: cache_dir, category: "pr-status")
    end

    test "status/3 returns status for specified category", %{cache_dir: cache_dir} do
      pr_data = %{"total" => 10}

      :ok =
        Cache.put("test-repo", pr_data, cache_dir: cache_dir, category: "pr-status", ttl_hours: 2)

      {:ok, status} = Cache.status("test-repo", cache_dir: cache_dir, category: "pr-status")

      assert status.repository == "test-repo"
      assert status.exists == true
      assert status.expired == false
    end

    test "categories are isolated from each other", %{cache_dir: cache_dir} do
      activity_data = %{"type" => "activity"}
      pr_data = %{"type" => "pr-status"}

      :ok = Cache.put("same-repo", activity_data, cache_dir: cache_dir, category: "activity")
      :ok = Cache.put("same-repo", pr_data, cache_dir: cache_dir, category: "pr-status")

      {:ok, retrieved_activity} =
        Cache.get("same-repo", cache_dir: cache_dir, category: "activity")

      {:ok, retrieved_pr} = Cache.get("same-repo", cache_dir: cache_dir, category: "pr-status")

      assert retrieved_activity["type"] == "activity"
      assert retrieved_pr["type"] == "pr-status"
    end

    test "TTL can be set per category", %{cache_dir: cache_dir} do
      # activity: 1時間TTL（デフォルト）
      :ok =
        Cache.put("repo1", %{"data" => 1},
          cache_dir: cache_dir,
          category: "activity",
          ttl_hours: 1
        )

      # pr-status: 5分TTL（0.083時間）
      :ok =
        Cache.put("repo2", %{"data" => 2},
          cache_dir: cache_dir,
          category: "pr-status",
          ttl_minutes: 5
        )

      {:ok, activity_status} = Cache.status("repo1", cache_dir: cache_dir, category: "activity")
      {:ok, pr_status} = Cache.status("repo2", cache_dir: cache_dir, category: "pr-status")

      # 両方とも有効
      refute activity_status.expired
      refute pr_status.expired
    end
  end

  describe "Cache.CacheStatus struct" do
    test "builds a struct dynamically with the expected fields" do
      # struct/2 を使うことで CacheStatus.__struct__ を実行時に呼び出し、
      # コンパイル時展開されるリテラル構文では到達しないコードを網羅する
      status =
        struct(Cache.CacheStatus, %{
          repository: "k21rs001-sotsuron",
          exists: true,
          expired: false,
          cached_at: "2025-01-01T00:00:00Z",
          expires_at: "2025-01-01T01:00:00Z",
          size_bytes: 42
        })

      assert %Cache.CacheStatus{} = status
      assert status.repository == "k21rs001-sotsuron"
      assert status.exists
      refute status.expired
      assert status.size_bytes == 42
    end

    test "defaults all fields to nil when built empty" do
      status = struct(Cache.CacheStatus, %{})
      assert status.repository == nil
      assert status.size_bytes == nil
    end
  end
end
