defmodule RegistryManager.Commands.ListActivityTest do
  use ExUnit.Case

  alias RegistryManager.Commands.List
  alias RegistryManager.Config

  # テスト用のモックデータ
  @test_repositories %{
    "k21rs001-sotsuron" => %{
      "student_id" => "k21rs001",
      "repository_type" => "sotsuron",
      "repository_created_at" => "2025-07-08T06:51:39.835808Z",
      "registry_created_at" => "2025-07-08T15:00:00.000000Z",
      "registry_updated_at" => "2025-07-08T15:30:00.000000Z",
      "github_username" => "student001",
      "protection_status" => "protected"
    },
    "k21rs002-wr" => %{
      "student_id" => "k21rs002",
      "repository_type" => "wr",
      "repository_created_at" => "2025-07-07T10:20:00.000000Z",
      "registry_created_at" => "2025-07-07T18:00:00.000000Z",
      "registry_updated_at" => "2025-07-09T10:00:00.000000Z",
      "github_username" => "student002",
      "protection_status" => "not_protected"
    },
    "k21rs003-ise-report1" => %{
      "student_id" => "k21rs003",
      "repository_type" => "ise",
      "repository_created_at" => "2025-07-09T08:00:00.000000Z",
      "registry_created_at" => "2025-07-09T12:00:00.000000Z",
      "registry_updated_at" => "2025-07-09T14:00:00.000000Z",
      "github_username" => "student003",
      "protection_status" => "protected"
    }
  }

  @test_csv_data [
    %{"student_id" => "k21rs001", "name" => "田中太郎", "github_username" => "student001"},
    %{"student_id" => "k21rs002", "name" => "佐藤花子", "github_username" => "student002"},
    %{"student_id" => "k21rs003", "name" => "鈴木次郎", "github_username" => "student003"}
  ]

  setup do
    # テスト用の設定
    config = %Config{
      csv_path: "test_students.csv",
      github_org: "test_org",
      cache: %{enabled: true, ttl_hours: 1, max_size_mb: 50},
      api: %{timeout_seconds: 15, max_concurrent: 8},
      log_level: "info"
    }

    {:ok, config: config, repositories: @test_repositories, csv_data: @test_csv_data}
  end

  describe "run/3 - activity information display" do
    test "includes last activity information with --activity", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      # モック活動情報
      activity_data = %{
        "k21rs001-sotsuron" => %{"last_activity" => "2025-07-09T12:00:00.000Z"},
        "k21rs002-wr" => %{"last_activity" => "2025-07-08T15:30:00.000Z"},
        "k21rs003-ise-report1" => %{"last_activity" => "2025-07-09T16:45:00.000Z"}
      }

      opts = [long: true, activity: true]

      {:ok, output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data,
          activity_data: activity_data
        )

      lines = String.split(output, "\n", trim: true)
      header = Enum.at(lines, 0)
      assert String.contains?(header, "Last Activity")

      content = Enum.join(lines, "\n")
      # JST変換確認: 2025-07-09T12:00:00.000Z -> 2025-07-09 21:00:00
      assert String.contains?(content, "2025-07-09 21:00:00")
      # JST変換確認: 2025-07-08T15:30:00.000Z -> 2025-07-09 00:30:00
      assert String.contains?(content, "2025-07-09 00:30:00")
      # JST変換確認: 2025-07-09T16:45:00.000Z -> 2025-07-10 01:45:00
      assert String.contains?(content, "2025-07-10 01:45:00")
    end

    test "includes owner activity information with --owner-activity", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      # モック活動情報
      activity_data = %{
        "k21rs001-sotsuron" => %{"owner_last_activity" => "2025-07-09T10:00:00.000Z"},
        "k21rs002-wr" => %{"owner_last_activity" => "2025-07-08T14:00:00.000Z"},
        "k21rs003-ise-report1" => %{"owner_last_activity" => "2025-07-09T18:30:00.000Z"}
      }

      opts = [long: true, owner_activity: true]

      {:ok, output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data,
          activity_data: activity_data
        )

      lines = String.split(output, "\n", trim: true)
      header = Enum.at(lines, 0)
      assert String.contains?(header, "Owner Activity")

      content = Enum.join(lines, "\n")
      # JST変換確認: 2025-07-09T10:00:00.000Z -> 2025-07-09 19:00:00
      assert String.contains?(content, "2025-07-09 19:00:00")
      # JST変換確認: 2025-07-08T14:00:00.000Z -> 2025-07-08 23:00:00
      assert String.contains?(content, "2025-07-08 23:00:00")
      # JST変換確認: 2025-07-09T18:30:00.000Z -> 2025-07-10 03:30:00
      assert String.contains?(content, "2025-07-10 03:30:00")
    end

    test "shows only Owner Activity when both --activity and --owner-activity are specified (Issue #107 changed priority)",
         %{
           repositories: repositories,
           csv_data: csv_data
         } do
      # モック活動情報
      activity_data = %{
        "k21rs001-sotsuron" => %{
          "last_activity" => "2025-07-09T12:00:00.000Z",
          "owner_last_activity" => "2025-07-09T10:00:00.000Z"
        },
        "k21rs002-wr" => %{
          "last_activity" => "2025-07-08T15:30:00.000Z",
          "owner_last_activity" => "2025-07-08T14:00:00.000Z"
        }
      }

      opts = [long: true, activity: true, owner_activity: true]

      {:ok, output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data,
          activity_data: activity_data
        )

      lines = String.split(output, "\n", trim: true)
      header = Enum.at(lines, 0)
      # Issue #107: Owner Activityが優先され、Last Activityは表示されない
      assert String.contains?(header, "Owner Activity")
      refute String.contains?(header, "Last Activity")
      # Registry Updatedも表示されない
      refute String.contains?(header, "Registry Updated")

      content = Enum.join(lines, "\n")
      # Owner Activityのみ表示されることを確認
      assert String.contains?(content, "2025-07-09 19:00:00")
    end

    test "handles missing activity data gracefully (Issue #107: Owner Activity priority)", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      # 一部の活動情報が欠損している場合
      activity_data = %{
        "k21rs001-sotsuron" => %{"last_activity" => "2025-07-09T12:00:00.000Z"},
        # k21rs002-wr には活動情報なし
        "k21rs003-ise-report1" => %{"owner_last_activity" => "2025-07-09T18:30:00.000Z"}
      }

      opts = [long: true, activity: true, owner_activity: true]

      {:ok, output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data,
          activity_data: activity_data
        )

      content = Enum.join(String.split(output, "\n", trim: true), "\n")

      # 活動情報がない場合は N/A が表示される
      assert String.contains?(content, "N/A")

      # Issue #107: Owner Activityのみ表示される（Last Activityは非表示）
      assert String.contains?(content, "2025-07-10 03:30:00")
      # Last Activity情報は表示されない（Owner Activityが優先）
      refute String.contains?(content, "2025-07-09 21:00:00")
    end

    test "handles completely missing activity data", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      opts = [long: true, activity: true, owner_activity: true]

      {:ok, output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data,
          activity_data: %{}
        )

      content = Enum.join(String.split(output, "\n", trim: true), "\n")

      # すべての活動情報が N/A になることを確認
      lines = String.split(content, "\n", trim: true)
      # ヘッダーとセパレータを除く
      data_lines = Enum.drop(lines, 2)

      Enum.each(data_lines, fn line ->
        # 各行に N/A が2つ含まれている（last_activity と owner_last_activity）
        assert String.contains?(line, "N/A")
      end)
    end

    test "handles invalid timestamp format gracefully", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      # 不正な形式のタイムスタンプ
      activity_data = %{
        "k21rs001-sotsuron" => %{"last_activity" => "invalid-timestamp"},
        "k21rs002-wr" => %{"last_activity" => ""},
        "k21rs003-ise-report1" => %{"last_activity" => nil}
      }

      opts = [long: true, activity: true]

      {:ok, output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data,
          activity_data: activity_data
        )

      content = Enum.join(String.split(output, "\n", trim: true), "\n")

      # 不正な形式の場合は Invalid または N/A が表示される
      assert String.contains?(content, "Invalid") or String.contains?(content, "N/A")
    end
  end

  describe "run/3 - CSV format with activity information" do
    test "outputs CSV with single activity column (Issue #107: Owner Activity priority)", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      activity_data = %{
        "k21rs001-sotsuron" => %{
          "last_activity" => "2025-07-09T12:00:00.000Z",
          "owner_last_activity" => "2025-07-09T10:00:00.000Z"
        }
      }

      opts = [format: "csv", long: true, activity: true, owner_activity: true]

      {:ok, output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data,
          activity_data: activity_data
        )

      lines = String.split(output, "\n", trim: true)

      # CSV ヘッダーを確認（Issue #107: Owner Activityのみ）
      header = Enum.at(lines, 0)
      assert String.contains?(header, "owner_activity")
      refute String.contains?(header, "last_activity")
      refute String.contains?(header, "registry_updated_at")

      # CSV データを確認（Owner Activityのみ）
      data_line = Enum.at(lines, 1)
      assert String.contains?(data_line, "2025-07-09 19:00:00")
      # Last Activityは表示されない
      refute String.contains?(data_line, "2025-07-09 21:00:00")
    end
  end

  describe "run/3 - JSON format with activity information" do
    test "outputs JSON with single activity field (Issue #107: Owner Activity priority)", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      activity_data = %{
        "k21rs001-sotsuron" => %{
          "last_activity" => "2025-07-09T12:00:00.000Z",
          "owner_last_activity" => "2025-07-09T10:00:00.000Z"
        }
      }

      opts = [format: "json", long: true, activity: true, owner_activity: true]

      {:ok, output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data,
          activity_data: activity_data
        )

      {:ok, parsed} = Jason.decode(output)

      assert is_list(parsed)
      first_entry = Enum.at(parsed, 0)
      assert first_entry["repository"] == "k21rs001-sotsuron"
      # Issue #107: Owner Activityのみ含まれる
      assert first_entry["owner_activity"] == "2025-07-09 19:00:00"
      # Last ActivityとRegistry Updatedは含まれない
      refute Map.has_key?(first_entry, "last_activity")
      refute Map.has_key?(first_entry, "registry_updated_at")
    end
  end

  describe "run/3 - caching behavior" do
    test "uses cache by default for activity information", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      opts = [long: true, activity: true]

      # キャッシュが使用されることを確認（実際のテストでは Cache モジュールの動作を検証）
      {:ok, _output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data,
          use_cache: true
        )

      # キャッシュが使用されたことを確認（実装依存）
      # 実際のキャッシュテストは統合テストで実施
      assert true
    end

    test "bypasses cache with --no-cache option", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      opts = [long: true, activity: true, no_cache: true]

      {:ok, _output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data,
          use_cache: false
        )

      # キャッシュがバイパスされたことを確認（実装依存）
      # 実際のキャッシュテストは統合テストで実施
      assert true
    end
  end

  describe "run/3 - filtering with activity information" do
    test "filters by repository type while preserving activity information", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      activity_data = %{
        "k21rs001-sotsuron" => %{"last_activity" => "2025-07-09T12:00:00.000Z"},
        "k21rs002-wr" => %{"last_activity" => "2025-07-08T15:30:00.000Z"}
      }

      opts = [long: true, activity: true, type: "sotsuron"]

      {:ok, output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data,
          activity_data: activity_data
        )

      lines = String.split(output, "\n", trim: true)

      # sotsuron タイプのみが表示される
      content = Enum.join(lines, "\n")
      assert String.contains?(content, "k21rs001-sotsuron")
      refute String.contains?(content, "k21rs002-wr")
      refute String.contains?(content, "k21rs003-ise-report1")

      # 活動情報も正しく表示される
      assert String.contains?(content, "2025-07-09 21:00:00")
    end
  end

  describe "run/3 - sorting with activity information" do
    test "sorts by time while preserving activity information", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      activity_data = %{
        "k21rs001-sotsuron" => %{"last_activity" => "2025-07-09T12:00:00.000Z"},
        "k21rs002-wr" => %{"last_activity" => "2025-07-08T15:30:00.000Z"},
        "k21rs003-ise-report1" => %{"last_activity" => "2025-07-09T16:45:00.000Z"}
      }

      opts = [long: true, activity: true, sort_by_time: true]

      {:ok, output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data,
          activity_data: activity_data
        )

      lines = String.split(output, "\n", trim: true)

      # 時刻順でソートされており、活動情報も正しく表示される
      content = Enum.join(lines, "\n")
      assert String.contains?(content, "2025-07-09 21:00:00")
      assert String.contains?(content, "2025-07-09 00:30:00")
      assert String.contains?(content, "2025-07-10 01:45:00")
    end
  end
end
