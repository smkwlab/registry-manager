defmodule RegistryManager.Commands.CacheTest do
  use ExUnit.Case

  alias RegistryManager.Cache, as: CacheModule
  alias RegistryManager.Commands.Cache

  @test_cache_dir Path.join(System.tmp_dir!(), "registry_manager_cache_test")

  setup do
    # テスト用のキャッシュディレクトリを作成
    File.mkdir_p!(@test_cache_dir)

    # 既存のキャッシュファイルがあれば削除
    if File.exists?(@test_cache_dir) do
      File.rm_rf!(@test_cache_dir)
      File.mkdir_p!(@test_cache_dir)
    end

    # テストモードを有効にする
    Application.put_env(:registry_manager, :test_mode, true)

    on_exit(fn ->
      # テスト後にクリーンアップ
      if File.exists?(@test_cache_dir) do
        File.rm_rf!(@test_cache_dir)
      end

      Application.delete_env(:registry_manager, :test_mode)
    end)

    {:ok, cache_dir: @test_cache_dir}
  end

  describe "run/3 - cache status" do
    test "shows status for all cache entries", %{cache_dir: cache_dir} do
      # テスト用キャッシュを作成
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      :ok =
        CacheModule.put("k21rs002-wr", %{"last_activity" => "2025-07-09T13:00:00Z"},
          cache_dir: cache_dir
        )

      opts = []

      {:ok, output} = Cache.run(["status"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Cache Status")
      assert String.contains?(output, "k21rs001-sotsuron")
      assert String.contains?(output, "k21rs002-wr")
      assert String.contains?(output, "Valid")
      assert String.contains?(output, "bytes")
    end

    test "shows status for specific repository", %{cache_dir: cache_dir} do
      # テスト用キャッシュを作成
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      opts = []

      {:ok, output} = Cache.run(["status", "k21rs001-sotsuron"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "k21rs001-sotsuron")
      assert String.contains?(output, "Valid")

      # キャッシュ時刻が表示されることを確認（日時形式のパターンマッチ）
      assert String.contains?(output, "Cached at:")
      assert String.contains?(output, "Expires at:")
    end

    test "shows status for non-existent repository", %{cache_dir: cache_dir} do
      opts = []

      {:ok, output} = Cache.run(["status", "non-existent-repo"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "non-existent-repo")
      assert String.contains?(output, "Not cached")
    end

    test "shows expired cache status", %{cache_dir: cache_dir} do
      # 期限切れのキャッシュを作成
      :ok =
        CacheModule.put("expired-repo", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir,
          ttl_hours: 0
        )

      # 期限切れにする
      :timer.sleep(10)

      opts = []

      {:ok, output} = Cache.run(["status", "expired-repo"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "expired-repo")
      assert String.contains?(output, "Expired")
    end

    test "shows empty cache status", %{cache_dir: cache_dir} do
      opts = []

      {:ok, output} =
        Cache.run(["status"], opts,
          cache_dir: cache_dir,
          registry_data: %{}
        )

      assert String.contains?(output, "Cache Status")
      assert String.contains?(output, "No cache entries found")
    end

    test "shows all repositories from registry including non-cached ones (Issue #99)", %{
      cache_dir: cache_dir
    } do
      # モックレジストリデータを設定
      registry_data = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "created_at" => "2025-07-01T00:00:00Z"
        },
        "k21rs002-wr" => %{
          "student_id" => "k21rs002",
          "repository_type" => "wr",
          "created_at" => "2025-07-01T00:00:00Z"
        },
        "k21rs003-ise-report" => %{
          "student_id" => "k21rs003",
          "repository_type" => "ise-report",
          "created_at" => "2025-07-01T00:00:00Z"
        }
      }

      # 一部のリポジトリのみキャッシュを作成
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      # k21rs002-wr と k21rs003-ise-report はキャッシュなし

      opts = []

      {:ok, output} =
        Cache.run(["status"], opts,
          cache_dir: cache_dir,
          registry_data: registry_data
        )

      # すべてのリポジトリが表示されることを確認
      assert String.contains?(output, "k21rs001-sotsuron")
      assert String.contains?(output, "k21rs002-wr")
      assert String.contains?(output, "k21rs003-ise-report")

      # キャッシュされているリポジトリは "Valid" として表示
      lines = String.split(output, "\n")
      sotsuron_line = Enum.find(lines, &String.contains?(&1, "k21rs001-sotsuron"))
      assert String.contains?(sotsuron_line, "Valid")

      # キャッシュされていないリポジトリは "Not cached" として表示
      wr_line = Enum.find(lines, &String.contains?(&1, "k21rs002-wr"))
      assert String.contains?(wr_line, "Not cached")

      ise_line = Enum.find(lines, &String.contains?(&1, "k21rs003-ise-report"))
      assert String.contains?(ise_line, "Not cached")
    end
  end

  describe "run/3 - cache clear" do
    test "clears all cache entries", %{cache_dir: cache_dir} do
      # テスト用キャッシュを作成
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      :ok =
        CacheModule.put("k21rs002-wr", %{"last_activity" => "2025-07-09T13:00:00Z"},
          cache_dir: cache_dir
        )

      # キャッシュが存在することを確認
      assert {:ok, _} = CacheModule.get("k21rs001-sotsuron", cache_dir: cache_dir)
      assert {:ok, _} = CacheModule.get("k21rs002-wr", cache_dir: cache_dir)

      opts = []

      {:ok, output} = Cache.run(["clear"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Cache cleared successfully")

      # キャッシュが削除されていることを確認
      assert {:error, :cache_miss} = CacheModule.get("k21rs001-sotsuron", cache_dir: cache_dir)
      assert {:error, :cache_miss} = CacheModule.get("k21rs002-wr", cache_dir: cache_dir)
    end

    test "clears specific repository cache", %{cache_dir: cache_dir} do
      # テスト用キャッシュを作成
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      :ok =
        CacheModule.put("k21rs002-wr", %{"last_activity" => "2025-07-09T13:00:00Z"},
          cache_dir: cache_dir
        )

      opts = []

      {:ok, output} = Cache.run(["clear", "k21rs001-sotsuron"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Cache cleared for k21rs001-sotsuron")

      # 指定されたキャッシュのみ削除されていることを確認
      assert {:error, :cache_miss} = CacheModule.get("k21rs001-sotsuron", cache_dir: cache_dir)
      assert {:ok, _} = CacheModule.get("k21rs002-wr", cache_dir: cache_dir)
    end

    test "clears non-existent repository cache gracefully", %{cache_dir: cache_dir} do
      opts = []

      {:ok, output} = Cache.run(["clear", "non-existent-repo"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Cache cleared for non-existent-repo")
    end

    test "confirms before clearing all cache with --force", %{cache_dir: cache_dir} do
      # テスト用キャッシュを作成
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      opts = [force: true]

      {:ok, output} = Cache.run(["clear"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Cache cleared successfully")
      assert {:error, :cache_miss} = CacheModule.get("k21rs001-sotsuron", cache_dir: cache_dir)
    end
  end

  describe "run/3 - cache refresh" do
    test "refreshes all cache entries", %{cache_dir: cache_dir} do
      # テスト用キャッシュを作成
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      :ok =
        CacheModule.put("k21rs002-wr", %{"last_activity" => "2025-07-09T13:00:00Z"},
          cache_dir: cache_dir
        )

      opts = []

      {:ok, output} = Cache.run(["refresh"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Cache refreshed successfully")

      # キャッシュが削除されていることを確認（次回アクセス時に再取得される）
      assert {:error, :cache_miss} = CacheModule.get("k21rs001-sotsuron", cache_dir: cache_dir)
      assert {:error, :cache_miss} = CacheModule.get("k21rs002-wr", cache_dir: cache_dir)
    end

    test "refreshes specific repository cache", %{cache_dir: cache_dir} do
      # テスト用キャッシュを作成
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      :ok =
        CacheModule.put("k21rs002-wr", %{"last_activity" => "2025-07-09T13:00:00Z"},
          cache_dir: cache_dir
        )

      opts = []

      {:ok, output} = Cache.run(["refresh", "k21rs001-sotsuron"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Cache refreshed for k21rs001-sotsuron")

      # 指定されたキャッシュのみ削除されていることを確認
      assert {:error, :cache_miss} = CacheModule.get("k21rs001-sotsuron", cache_dir: cache_dir)
      assert {:ok, _} = CacheModule.get("k21rs002-wr", cache_dir: cache_dir)
    end

    test "refreshes non-existent repository cache gracefully", %{cache_dir: cache_dir} do
      opts = []

      {:ok, output} = Cache.run(["refresh", "non-existent-repo"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Cache refreshed for non-existent-repo")
    end
  end

  describe "run/3 - hyphenated aliases" do
    test "cache-status alias works", %{cache_dir: cache_dir} do
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      opts = []

      {:ok, output} = Cache.run(["cache-status"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Cache Status")
      assert String.contains?(output, "k21rs001-sotsuron")
    end

    test "cache-clear alias works", %{cache_dir: cache_dir} do
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      opts = []

      {:ok, output} = Cache.run(["cache-clear"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Cache cleared successfully")
      assert {:error, :cache_miss} = CacheModule.get("k21rs001-sotsuron", cache_dir: cache_dir)
    end

    test "cache-refresh alias works", %{cache_dir: cache_dir} do
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      opts = []

      {:ok, output} = Cache.run(["cache-refresh"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Cache refreshed successfully")
      assert {:error, :cache_miss} = CacheModule.get("k21rs001-sotsuron", cache_dir: cache_dir)
    end

    test "hyphenated aliases work with specific repository", %{cache_dir: cache_dir} do
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      opts = []

      {:ok, output} = Cache.run(["cache-status", "k21rs001-sotsuron"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "k21rs001-sotsuron")
      assert String.contains?(output, "Valid")
    end
  end

  describe "run/3 - verbose output" do
    test "shows verbose output with --verbose", %{cache_dir: cache_dir} do
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      opts = [verbose: true]

      {:ok, output} = Cache.run(["status"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Cache directory:")
      assert String.contains?(output, cache_dir)
    end

    test "shows verbose output for cache operations", %{cache_dir: cache_dir} do
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      opts = [verbose: true]

      {:ok, output} = Cache.run(["clear"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Clearing cache")
      assert String.contains?(output, "All cache entries cleared from")
    end
  end

  describe "run/3 - error handling" do
    test "handles invalid cache commands" do
      opts = []

      {:error, reason} = Cache.run(["invalid"], opts, cache_dir: @test_cache_dir)

      assert String.contains?(reason, "Invalid cache command")
    end

    test "handles too many arguments for status" do
      opts = []

      {:error, reason} = Cache.run(["status", "repo1", "repo2"], opts, cache_dir: @test_cache_dir)

      assert String.contains?(reason, "Too many arguments")
    end

    test "handles too many arguments for clear" do
      opts = []

      {:error, reason} = Cache.run(["clear", "repo1", "repo2"], opts, cache_dir: @test_cache_dir)

      assert String.contains?(reason, "Too many arguments")
    end

    test "handles too many arguments for refresh" do
      opts = []

      {:error, reason} =
        Cache.run(["refresh", "repo1", "repo2"], opts, cache_dir: @test_cache_dir)

      assert String.contains?(reason, "Too many arguments")
    end
  end

  describe "run/3 - cache statistics" do
    test "shows cache statistics in status output", %{cache_dir: cache_dir} do
      # 複数のキャッシュを作成
      :ok =
        CacheModule.put("k21rs001-sotsuron", %{"last_activity" => "2025-07-09T12:00:00Z"},
          cache_dir: cache_dir
        )

      :ok =
        CacheModule.put("k21rs002-wr", %{"last_activity" => "2025-07-09T13:00:00Z"},
          cache_dir: cache_dir
        )

      :ok =
        CacheModule.put("expired-repo", %{"last_activity" => "2025-07-09T11:00:00Z"},
          cache_dir: cache_dir,
          ttl_hours: 0
        )

      # 期限切れにする
      :timer.sleep(10)

      opts = []

      {:ok, output} = Cache.run(["status"], opts, cache_dir: cache_dir)

      assert String.contains?(output, "Total entries:")
      assert String.contains?(output, "Valid entries:")
      assert String.contains?(output, "Expired entries:")
      assert String.contains?(output, "Total size:")
    end
  end

  describe "format_cache_status/2" do
    test "formats single repository status correctly" do
      status = %CacheModule.CacheStatus{
        repository: "k21rs001-sotsuron",
        exists: true,
        expired: false,
        cached_at: "2025-07-09T12:00:00Z",
        expires_at: "2025-07-09T13:00:00Z",
        size_bytes: 256
      }

      output = Cache.format_cache_status(status, false)

      assert String.contains?(output, "k21rs001-sotsuron")
      assert String.contains?(output, "Valid")
      assert String.contains?(output, "256 bytes")
    end

    test "formats expired cache status correctly" do
      status = %CacheModule.CacheStatus{
        repository: "expired-repo",
        exists: true,
        expired: true,
        cached_at: "2025-07-09T12:00:00Z",
        expires_at: "2025-07-09T12:30:00Z",
        size_bytes: 128
      }

      output = Cache.format_cache_status(status, false)

      assert String.contains?(output, "expired-repo")
      assert String.contains?(output, "Expired")
      assert String.contains?(output, "128 bytes")
    end

    test "formats non-existent cache status correctly" do
      status = %CacheModule.CacheStatus{
        repository: "non-existent-repo",
        exists: false,
        expired: false,
        cached_at: nil,
        expires_at: nil,
        size_bytes: 0
      }

      output = Cache.format_cache_status(status, false)

      assert String.contains?(output, "non-existent-repo")
      assert String.contains?(output, "Not cached")
      assert String.contains?(output, "0 bytes")
    end
  end
end
