defmodule RegistryManager.Commands.PrStatusTest do
  use ExUnit.Case, async: true

  alias RegistryManager.Commands.PrStatus

  # テストデータ
  @test_repositories %{
    "k21rs001-sotsuron" => %{
      "student_id" => "k21rs001",
      "repository_type" => "sotsuron",
      "created_at" => "2024-01-01 10:00:00 UTC",
      "updated_at" => "2024-01-15 15:30:00 UTC"
    },
    "k21rs002-wr" => %{
      "student_id" => "k21rs002",
      "repository_type" => "wr",
      "created_at" => "2024-01-02 09:00:00 UTC",
      "updated_at" => "2024-01-10 14:20:00 UTC"
    },
    "k21rs003-ise" => %{
      "student_id" => "k21rs003",
      "repository_type" => "ise",
      "created_at" => "2024-01-03 11:00:00 UTC",
      "updated_at" => "2024-01-05 16:45:00 UTC"
    },
    "k94gjk01-master" => %{
      "student_id" => "k94gjk01",
      "repository_type" => "master",
      "created_at" => "2024-01-04 12:00:00 UTC",
      "updated_at" => "2024-01-20 10:00:00 UTC"
    },
    "k94gjk02-master" => %{
      "student_id" => "k94gjk02",
      "repository_type" => "master",
      "created_at" => "2024-01-05 13:00:00 UTC",
      "updated_at" => "2024-01-21 11:00:00 UTC"
    },
    "k95gjk03-wakate-ronbun" => %{
      "student_id" => "k95gjk03",
      "repository_type" => "other",
      "created_at" => "2024-01-06 14:00:00 UTC",
      "updated_at" => "2024-01-22 12:00:00 UTC"
    }
  }

  @test_pr_data %{
    "k21rs001-sotsuron" => %{
      total: 5,
      open: 1,
      closed: 2,
      merged: 2,
      draft: 0,
      status: "In Progress",
      updated_at: "2024-01-20T15:30:00Z",
      created_at: "2024-01-01T10:00:00Z"
    },
    "k21rs002-wr" => %{
      total: 0,
      open: 0,
      closed: 0,
      merged: 0,
      draft: 0,
      status: "No PRs",
      updated_at: "2024-01-10T14:20:00Z",
      created_at: "2024-01-02T09:00:00Z"
    },
    "k21rs003-ise" => %{
      total: 3,
      open: 0,
      closed: 0,
      merged: 3,
      draft: 0,
      status: "Complete",
      updated_at: "2024-01-25T16:45:00Z",
      created_at: "2024-01-03T11:00:00Z"
    },
    "k94gjk01-master" => %{
      total: 2,
      open: 1,
      closed: 0,
      merged: 1,
      draft: 0,
      status: "In Progress",
      updated_at: "2024-01-22T10:00:00Z",
      created_at: "2024-01-04T12:00:00Z"
    },
    "k94gjk02-master" => %{
      total: 1,
      open: 0,
      closed: 0,
      merged: 1,
      draft: 0,
      status: "Complete",
      updated_at: "2024-01-15T11:00:00Z",
      created_at: "2024-01-05T13:00:00Z"
    },
    "k95gjk03-wakate-ronbun" => %{
      total: 0,
      open: 0,
      closed: 0,
      merged: 0,
      draft: 0,
      status: "No PRs",
      updated_at: "2024-01-05T12:00:00Z",
      created_at: "2024-01-06T14:00:00Z"
    }
  }

  describe "run/3" do
    test "displays pr status in table format by default" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [], test_params)

      assert String.contains?(output, "Repository")
      assert String.contains?(output, "Total PRs")
      assert String.contains?(output, "Open")
      assert String.contains?(output, "Status")
      assert String.contains?(output, "k21rs001-sotsuron")
      assert String.contains?(output, "In Progress")
      assert String.contains?(output, "k21rs002-wr")
      assert String.contains?(output, "No PRs")
      assert String.contains?(output, "k21rs003-ise")
      assert String.contains?(output, "Complete")
    end

    test "displays pr status in CSV format" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [format: "csv"], test_params)

      lines = String.split(output, "\n", trim: true)
      # ヘッダー + 3データ行
      assert length(lines) >= 4

      # ヘッダー確認
      header = List.first(lines)
      assert String.contains?(header, "repository")
      assert String.contains?(header, "total_prs")
      assert String.contains?(header, "status")

      # データ行確認
      assert Enum.any?(lines, &String.contains?(&1, "k21rs001-sotsuron,5,1,2,2,0,In Progress"))
      assert Enum.any?(lines, &String.contains?(&1, "k21rs002-wr,0,0,0,0,0,No PRs"))
      assert Enum.any?(lines, &String.contains?(&1, "k21rs003-ise,3,0,0,3,0,Complete"))
    end

    test "displays pr status in JSON format" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [format: "json"], test_params)

      {:ok, parsed} = Jason.decode(output)
      assert is_list(parsed)
      assert length(parsed) == 6

      repo1 = Enum.find(parsed, &(&1["repository"] == "k21rs001-sotsuron"))
      assert repo1["total_prs"] == 5
      assert repo1["open_prs"] == 1
      assert repo1["status"] == "In Progress"

      repo2 = Enum.find(parsed, &(&1["repository"] == "k21rs002-wr"))
      assert repo2["total_prs"] == 0
      assert repo2["status"] == "No PRs"
    end

    test "filters by repository type" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [type: "wr"], test_params)

      assert String.contains?(output, "k21rs002-wr")
      refute String.contains?(output, "k21rs001-sotsuron")
      refute String.contains?(output, "k21rs003-ise")
    end

    # Issue #111: New type filter tests
    test "filters by type=master to show only master repositories" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [type: "master"], test_params)

      assert String.contains?(output, "k94gjk01-master")
      assert String.contains?(output, "k94gjk02-master")
      refute String.contains?(output, "k21rs001-sotsuron")
      refute String.contains?(output, "k21rs002-wr")
      refute String.contains?(output, "k95gjk03-wakate-ronbun")
    end

    test "filters by type=thesis to show both sotsuron and master repositories" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [type: "thesis"], test_params)

      # thesis shows both sotsuron and master
      assert String.contains?(output, "k21rs001-sotsuron")
      assert String.contains?(output, "k94gjk01-master")
      assert String.contains?(output, "k94gjk02-master")
      # but not wr, ise, or other
      refute String.contains?(output, "k21rs002-wr")
      refute String.contains?(output, "k21rs003-ise")
      refute String.contains?(output, "k95gjk03-wakate-ronbun")
    end

    test "filters by type=other to show only other repositories" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [type: "other"], test_params)

      assert String.contains?(output, "k95gjk03-wakate-ronbun")
      refute String.contains?(output, "k21rs001-sotsuron")
      refute String.contains?(output, "k94gjk01-master")
      refute String.contains?(output, "k21rs002-wr")
    end

    test "filters by PR state" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [state: "open"], test_params)

      # オープンなPRがあるリポジトリのみ表示
      assert String.contains?(output, "k21rs001-sotsuron")
      # PRなし
      refute String.contains?(output, "k21rs002-wr")
      # PRは全てマージ済み
      refute String.contains?(output, "k21rs003-ise")
    end

    test "returns error for invalid format" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:error, message} = PrStatus.run([], [format: "invalid"], test_params)
      assert String.contains?(message, "Invalid format")
    end

    test "returns error for invalid type" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:error, message} = PrStatus.run([], [type: "invalid"], test_params)
      assert String.contains?(message, "Invalid type")
    end

    test "handles empty repository list" do
      test_params = [
        repositories: %{},
        pr_data: %{}
      ]

      {:ok, output} = PrStatus.run([], [], test_params)
      assert String.contains?(output, "No repositories found")
    end

    test "handles GitHub API errors gracefully" do
      test_params = [
        repositories: @test_repositories,
        api_error: "API rate limit exceeded"
      ]

      {:error, message} = PrStatus.run([], [], test_params)
      assert String.contains?(message, "API rate limit exceeded")
    end

    test "filters by state=closed (closed/merged with no open PRs)" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [state: "closed"], test_params)

      # k21rs003-ise: all 3 merged, 0 open → shown
      assert String.contains?(output, "k21rs003-ise")
      # k94gjk02-master: 1 merged, 0 open → shown
      assert String.contains?(output, "k94gjk02-master")
      # k21rs001-sotsuron: has 1 open → excluded
      refute String.contains?(output, "k21rs001-sotsuron")
      # k21rs002-wr: no PRs at all → excluded
      refute String.contains?(output, "k21rs002-wr")
    end
  end

  describe "sort with missing timestamps" do
    @repos_no_ts %{
      "b-repo" => %{"repository_type" => "wr"},
      "a-repo" => %{"repository_type" => "wr"}
    }

    test "sort=updated falls back to epoch when updated_at is missing" do
      pr_data = %{
        "a-repo" => %{total: 1, open: 1, closed: 0, merged: 0, draft: 0, status: "Open"},
        "b-repo" => %{total: 1, open: 1, closed: 0, merged: 0, draft: 0, status: "Open"}
      }

      test_params = [repositories: @repos_no_ts, pr_data: pr_data]

      {:ok, output} = PrStatus.run([], [format: "csv", sort: "updated"], test_params)
      assert String.contains?(output, "a-repo")
      assert String.contains?(output, "b-repo")
    end

    test "sort=created falls back to epoch when created_at is missing" do
      pr_data = %{
        "a-repo" => %{total: 1, open: 1, closed: 0, merged: 0, draft: 0, status: "Open"},
        "b-repo" => %{total: 1, open: 1, closed: 0, merged: 0, draft: 0, status: "Open"}
      }

      test_params = [repositories: @repos_no_ts, pr_data: pr_data]

      {:ok, output} = PrStatus.run([], [format: "csv", sort: "created"], test_params)
      assert String.contains?(output, "a-repo")
      assert String.contains?(output, "b-repo")
    end

    test "sort=updated tolerates a non-string updated_at value" do
      pr_data = %{
        "a-repo" => %{
          total: 1,
          open: 1,
          closed: 0,
          merged: 0,
          draft: 0,
          status: "Open",
          updated_at: 12_345
        }
      }

      test_params = [repositories: %{"a-repo" => %{"repository_type" => "wr"}}, pr_data: pr_data]

      {:ok, output} = PrStatus.run([], [format: "csv", sort: "updated"], test_params)
      assert String.contains?(output, "a-repo")
    end
  end

  describe "option validation" do
    test "validates format option" do
      assert {:ok, _} = PrStatus.validate_options(format: "table")
      assert {:ok, _} = PrStatus.validate_options(format: "csv")
      assert {:ok, _} = PrStatus.validate_options(format: "json")
      assert {:error, _} = PrStatus.validate_options(format: "xml")
    end

    test "validates type option" do
      assert {:ok, _} = PrStatus.validate_options(type: "wr")
      assert {:ok, _} = PrStatus.validate_options(type: "ise")
      assert {:ok, _} = PrStatus.validate_options(type: "sotsuron")
      # Issue #111: Added master and other types
      assert {:ok, _} = PrStatus.validate_options(type: "master")
      assert {:ok, _} = PrStatus.validate_options(type: "thesis")
      assert {:ok, _} = PrStatus.validate_options(type: "other")
      assert {:error, _} = PrStatus.validate_options(type: "invalid")
    end

    test "validates state option" do
      assert {:ok, _} = PrStatus.validate_options(state: "open")
      assert {:ok, _} = PrStatus.validate_options(state: "closed")
      assert {:ok, _} = PrStatus.validate_options(state: "all")
      assert {:error, _} = PrStatus.validate_options(state: "invalid")
    end

    # Issue #115: New sort option tests
    test "validates sort option" do
      assert {:ok, _} = PrStatus.validate_options(sort: "repository")
      assert {:ok, _} = PrStatus.validate_options(sort: "updated")
      assert {:ok, _} = PrStatus.validate_options(sort: "created")
      assert {:error, _} = PrStatus.validate_options(sort: "invalid")
    end

    test "review_requested option sets default sort to updated" do
      {:ok, opts} = PrStatus.validate_options(review_requested: true)
      assert opts[:sort] == "updated"
    end

    test "explicit sort option overrides review_requested default" do
      {:ok, opts} = PrStatus.validate_options(review_requested: true, sort: "repository")
      assert opts[:sort] == "repository"
    end

    test "validated opts contain exactly the consumed keys" do
      {:ok, opts} = PrStatus.validate_options([])

      assert Enum.sort(Keyword.keys(opts)) ==
               Enum.sort([:format, :type, :state, :no_cache, :sort, :reverse, :review_requested])
    end
  end

  # Issue #115: New tests for --review-requested and --sort options
  describe "review_requested filtering" do
    test "filters by review_requested when enabled" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data,
        current_user: "testuser",
        pending_reviews: %{
          "k21rs001-sotsuron" => true,
          "k21rs002-wr" => false,
          "k21rs003-ise" => false,
          "k94gjk01-master" => true,
          "k94gjk02-master" => false,
          "k95gjk03-wakate-ronbun" => false
        }
      ]

      {:ok, output} = PrStatus.run([], [review_requested: true], test_params)

      # Only repos with pending review requests should appear
      assert String.contains?(output, "k21rs001-sotsuron")
      assert String.contains?(output, "k94gjk01-master")
      refute String.contains?(output, "k21rs002-wr")
      refute String.contains?(output, "k21rs003-ise")
      refute String.contains?(output, "k94gjk02-master")
      refute String.contains?(output, "k95gjk03-wakate-ronbun")
    end

    test "review_requested defaults to updated_at descending order end to end" do
      # Issue #58: GitHub の review-requested 一覧と同じ並び（updated_at 降順）に
      # なることをパイプライン全体で保証する（明示 sort なし）
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data,
        current_user: "testuser",
        pending_reviews: %{
          "k21rs001-sotsuron" => true,
          "k21rs002-wr" => true,
          "k21rs003-ise" => true,
          "k94gjk01-master" => true,
          "k94gjk02-master" => true,
          "k95gjk03-wakate-ronbun" => true
        }
      ]

      {:ok, output} = PrStatus.run([], [format: "csv", review_requested: true], test_params)

      lines = String.split(output, "\n", trim: true) |> tl()
      repos = Enum.map(lines, fn line -> String.split(line, ",") |> hd() end)

      expected_order = [
        "k21rs003-ise",
        "k94gjk01-master",
        "k21rs001-sotsuron",
        "k94gjk02-master",
        "k21rs002-wr",
        "k95gjk03-wakate-ronbun"
      ]

      assert repos == expected_order
    end

    test "shows all repos when review_requested is false" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [review_requested: false], test_params)

      assert String.contains?(output, "k21rs001-sotsuron")
      assert String.contains?(output, "k21rs002-wr")
      assert String.contains?(output, "k21rs003-ise")
    end

    test "returns empty when no pending reviews" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data,
        current_user: "testuser",
        pending_reviews: %{
          "k21rs001-sotsuron" => false,
          "k21rs002-wr" => false,
          "k21rs003-ise" => false,
          "k94gjk01-master" => false,
          "k94gjk02-master" => false,
          "k95gjk03-wakate-ronbun" => false
        }
      ]

      {:ok, output} = PrStatus.run([], [review_requested: true], test_params)
      assert String.contains?(output, "No repositories found")
    end
  end

  describe "sort option" do
    test "sorts by repository name by default" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [format: "csv"], test_params)

      lines = String.split(output, "\n", trim: true) |> tl()
      repos = Enum.map(lines, fn line -> String.split(line, ",") |> hd() end)

      # Should be sorted alphabetically
      assert repos == Enum.sort(repos)
    end

    test "reverse option reverses sort order" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [format: "csv", reverse: true], test_params)

      lines = String.split(output, "\n", trim: true) |> tl()
      repos = Enum.map(lines, fn line -> String.split(line, ",") |> hd() end)

      # Should be sorted in reverse alphabetical order
      assert repos == Enum.sort(repos, :desc)
    end

    test "sorts by updated_at when sort=updated" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [format: "csv", sort: "updated"], test_params)

      lines = String.split(output, "\n", trim: true) |> tl()
      repos = Enum.map(lines, fn line -> String.split(line, ",") |> hd() end)

      # Expected order by updated_at descending:
      # k21rs003-ise: 2024-01-25T16:45:00Z
      # k94gjk01-master: 2024-01-22T10:00:00Z
      # k21rs001-sotsuron: 2024-01-20T15:30:00Z
      # k94gjk02-master: 2024-01-15T11:00:00Z
      # k21rs002-wr: 2024-01-10T14:20:00Z
      # k95gjk03-wakate-ronbun: 2024-01-05T12:00:00Z
      expected_order = [
        "k21rs003-ise",
        "k94gjk01-master",
        "k21rs001-sotsuron",
        "k94gjk02-master",
        "k21rs002-wr",
        "k95gjk03-wakate-ronbun"
      ]

      assert repos == expected_order
    end

    test "sorts by created_at when sort=created" do
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data
      ]

      {:ok, output} = PrStatus.run([], [format: "csv", sort: "created"], test_params)

      lines = String.split(output, "\n", trim: true) |> tl()
      repos = Enum.map(lines, fn line -> String.split(line, ",") |> hd() end)

      # Expected order by created_at descending:
      # k95gjk03-wakate-ronbun: 2024-01-06T14:00:00Z
      # k94gjk02-master: 2024-01-05T13:00:00Z
      # k94gjk01-master: 2024-01-04T12:00:00Z
      # k21rs003-ise: 2024-01-03T11:00:00Z
      # k21rs002-wr: 2024-01-02T09:00:00Z
      # k21rs001-sotsuron: 2024-01-01T10:00:00Z
      expected_order = [
        "k95gjk03-wakate-ronbun",
        "k94gjk02-master",
        "k94gjk01-master",
        "k21rs003-ise",
        "k21rs002-wr",
        "k21rs001-sotsuron"
      ]

      assert repos == expected_order
    end
  end

  # Issue #120: キャッシュ機能のテスト
  describe "caching functionality" do
    @cache_dir Path.join(System.tmp_dir!(), "pr_status_cache_test")
    @cache_category "pr-status"

    setup do
      # テスト用キャッシュディレクトリを作成
      File.mkdir_p!(Path.join(@cache_dir, @cache_category))

      on_exit(fn ->
        # テスト後にクリーンアップ
        if File.exists?(@cache_dir) do
          File.rm_rf!(@cache_dir)
        end
      end)

      {:ok, cache_dir: @cache_dir}
    end

    test "caches PR data when fetched from API", %{cache_dir: cache_dir} do
      # キャッシュ有効なオプションでテスト実行
      test_params = [
        repositories: @test_repositories,
        pr_data: @test_pr_data,
        cache_dir: cache_dir
      ]

      # 初回実行
      {:ok, _output} = PrStatus.run([], [format: "table"], test_params)

      # キャッシュファイルが作成されることを確認
      cache_file = Path.join([cache_dir, @cache_category, "k21rs001-sotsuron.json"])
      assert File.exists?(cache_file), "Cache file should be created"
    end

    test "uses cached data when available and not expired", %{cache_dir: cache_dir} do
      alias RegistryManager.Cache

      # 事前にキャッシュを保存
      cached_data = %{
        total: 99,
        open: 50,
        closed: 25,
        merged: 24,
        draft: 0,
        status: "Cached Data"
      }

      :ok =
        Cache.put("k21rs001-sotsuron", cached_data,
          cache_dir: cache_dir,
          category: @cache_category,
          ttl_minutes: 5
        )

      # テスト実行時にキャッシュを使用
      test_params = [
        repositories: %{"k21rs001-sotsuron" => @test_repositories["k21rs001-sotsuron"]},
        cache_dir: cache_dir,
        use_cache: true
      ]

      {:ok, output} = PrStatus.run([], [format: "table"], test_params)

      # キャッシュされたデータが使われることを確認
      assert String.contains?(output, "99"), "Should use cached total value"
      assert String.contains?(output, "Cached Data"), "Should use cached status"
    end

    test "bypasses cache when --no-cache is specified", %{cache_dir: cache_dir} do
      alias RegistryManager.Cache

      # 事前にキャッシュを保存
      cached_data = %{
        total: 99,
        open: 50,
        closed: 25,
        merged: 24,
        draft: 0,
        status: "Old Cached Data"
      }

      :ok =
        Cache.put("k21rs001-sotsuron", cached_data,
          cache_dir: cache_dir,
          category: @cache_category,
          ttl_minutes: 5
        )

      # --no-cache オプションでテスト実行
      test_params = [
        repositories: %{"k21rs001-sotsuron" => @test_repositories["k21rs001-sotsuron"]},
        pr_data: %{
          "k21rs001-sotsuron" => %{
            total: 5,
            open: 1,
            closed: 2,
            merged: 2,
            draft: 0,
            status: "In Progress"
          }
        },
        cache_dir: cache_dir,
        use_cache: true
      ]

      {:ok, output} = PrStatus.run([], [format: "table", no_cache: true], test_params)

      # キャッシュではなく新しいデータが使われることを確認
      refute String.contains?(output, "99"), "Should not use cached total value"
      refute String.contains?(output, "Old Cached Data"), "Should not use cached status"
      assert String.contains?(output, "In Progress"), "Should use fresh data"
    end

    test "fetches fresh data when cache is expired", %{cache_dir: cache_dir} do
      alias RegistryManager.Cache

      # TTL=0 で即座に期限切れになるキャッシュを保存
      cached_data = %{
        total: 99,
        open: 50,
        closed: 25,
        merged: 24,
        draft: 0,
        status: "Expired Cached Data"
      }

      :ok =
        Cache.put("k21rs001-sotsuron", cached_data,
          cache_dir: cache_dir,
          category: @cache_category,
          ttl_hours: 0
        )

      # 少し待って期限切れにする
      :timer.sleep(10)

      test_params = [
        repositories: %{"k21rs001-sotsuron" => @test_repositories["k21rs001-sotsuron"]},
        pr_data: %{
          "k21rs001-sotsuron" => %{
            total: 5,
            open: 1,
            closed: 2,
            merged: 2,
            draft: 0,
            status: "Fresh Data"
          }
        },
        cache_dir: cache_dir,
        use_cache: true
      ]

      {:ok, output} = PrStatus.run([], [format: "table"], test_params)

      # 期限切れキャッシュではなく新しいデータが使われることを確認
      refute String.contains?(output, "99"), "Should not use expired cached total"

      refute String.contains?(output, "Expired Cached Data"),
             "Should not use expired cached status"

      assert String.contains?(output, "Fresh Data"), "Should use fresh data"
    end

    test "respects custom TTL setting", %{cache_dir: cache_dir} do
      alias RegistryManager.Cache

      test_params = [
        repositories: %{"k21rs001-sotsuron" => @test_repositories["k21rs001-sotsuron"]},
        pr_data: %{
          "k21rs001-sotsuron" => %{
            total: 5,
            open: 1,
            closed: 2,
            merged: 2,
            draft: 0,
            status: "In Progress"
          }
        },
        cache_dir: cache_dir,
        use_cache: true,
        cache_ttl_minutes: 10
      ]

      {:ok, _output} = PrStatus.run([], [format: "table"], test_params)

      # キャッシュステータスを確認
      {:ok, status} =
        Cache.status("k21rs001-sotsuron", cache_dir: cache_dir, category: @cache_category)

      assert status.exists, "Cache should exist"
      refute status.expired, "Cache should not be expired"

      # expires_at を確認（約10分後であるべき）
      {:ok, expires_at, _} = DateTime.from_iso8601(status.expires_at)
      now = DateTime.utc_now()
      diff_seconds = DateTime.diff(expires_at, now, :second)

      # TTL が 9分〜11分 の範囲にあることを確認（多少の誤差を許容）
      assert diff_seconds >= 540 and diff_seconds <= 660,
             "Cache TTL should be approximately 10 minutes, got #{diff_seconds} seconds"
    end
  end
end
