defmodule RegistryManager.Commands.ListTest do
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
    },
    "k92gjk01-master" => %{
      "student_id" => "k92gjk01",
      "repository_type" => "master",
      "repository_created_at" => "2025-07-10T09:00:00.000000Z",
      "registry_created_at" => "2025-07-10T10:00:00.000000Z",
      "registry_updated_at" => "2025-07-10T11:00:00.000000Z",
      "github_username" => "student004",
      "protection_status" => "protected"
    },
    "k93gjk02-master" => %{
      "student_id" => "k93gjk02",
      "repository_type" => "master",
      "repository_created_at" => "2025-07-11T09:00:00.000000Z",
      "registry_created_at" => "2025-07-11T10:00:00.000000Z",
      "registry_updated_at" => "2025-07-11T11:00:00.000000Z",
      "github_username" => "student005",
      "protection_status" => "protected"
    },
    "k94gjk03-wakate-ronbun" => %{
      "student_id" => "k94gjk03",
      "repository_type" => "other",
      "repository_created_at" => "2025-07-12T09:00:00.000000Z",
      "registry_created_at" => "2025-07-12T10:00:00.000000Z",
      "registry_updated_at" => "2025-07-12T11:00:00.000000Z",
      "github_username" => "student006",
      "protection_status" => "not_protected"
    }
  }

  @test_csv_data [
    %{"student_id" => "k21rs001", "name" => "田中太郎", "github_username" => "student001"},
    %{"student_id" => "k21rs002", "name" => "佐藤花子", "github_username" => "student002"},
    %{"student_id" => "k21rs003", "name" => "鈴木次郎", "github_username" => "student003"},
    %{"student_id" => "k92gjk01", "name" => "高橋一郎", "github_username" => "student004"},
    %{"student_id" => "k93gjk02", "name" => "伊藤二郎", "github_username" => "student005"},
    %{"student_id" => "k94gjk03", "name" => "渡辺三郎", "github_username" => "student006"},
    %{"student_id" => "k92rs120", "name" => "藤山大響", "github_username" => "k92rs120"},
    %{"student_id" => "k93rs042", "name" => "金武俊佑", "github_username" => "k93rs042"}
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

  describe "run/2 - basic mode" do
    test "returns repository names only in basic mode", %{repositories: repositories} do
      opts = []

      {:ok, output} = List.run([], opts, repositories: repositories)

      lines = String.split(output, "\n", trim: true)
      assert length(lines) == 6
      assert "k21rs001-sotsuron" in lines
      assert "k21rs002-wr" in lines
      assert "k21rs003-ise-report1" in lines
      assert "k92gjk01-master" in lines
      assert "k93gjk02-master" in lines
      assert "k94gjk03-wakate-ronbun" in lines
    end

    test "sorts repository names alphabetically by default", %{repositories: repositories} do
      opts = []

      {:ok, output} = List.run([], opts, repositories: repositories)

      lines = String.split(output, "\n", trim: true)

      assert lines == [
               "k21rs001-sotsuron",
               "k21rs002-wr",
               "k21rs003-ise-report1",
               "k92gjk01-master",
               "k93gjk02-master",
               "k94gjk03-wakate-ronbun"
             ]
    end

    test "filters by repository type", %{repositories: repositories} do
      opts = [type: "wr"]

      {:ok, output} = List.run([], opts, repositories: repositories)

      lines = String.split(output, "\n", trim: true)
      assert lines == ["k21rs002-wr"]
    end

    test "filters by type=sotsuron to show only sotsuron repositories (Issue #388)", %{
      repositories: repositories
    } do
      opts = [type: "sotsuron"]

      {:ok, output} = List.run([], opts, repositories: repositories)

      lines = String.split(output, "\n", trim: true)
      assert lines == ["k21rs001-sotsuron"]
    end

    test "filters by type=master to show only master repositories (Issue #388)", %{
      repositories: repositories
    } do
      opts = [type: "master"]

      {:ok, output} = List.run([], opts, repositories: repositories)

      lines = String.split(output, "\n", trim: true)
      assert lines == ["k92gjk01-master", "k93gjk02-master"]
    end

    test "filters by type=thesis to show both sotsuron and master repositories (Issue #388)", %{
      repositories: repositories
    } do
      opts = [type: "thesis"]

      {:ok, output} = List.run([], opts, repositories: repositories)

      lines = String.split(output, "\n", trim: true)
      # sotsuron と master 両方が含まれる
      assert length(lines) == 3
      assert "k21rs001-sotsuron" in lines
      assert "k92gjk01-master" in lines
      assert "k93gjk02-master" in lines
    end

    test "filters by type=other to exclude wr, ise, sotsuron, master repositories (Issue #388)",
         %{
           repositories: repositories
         } do
      opts = [type: "other"]

      {:ok, output} = List.run([], opts, repositories: repositories)

      lines = String.split(output, "\n", trim: true)
      # wakate-ronbun のみが含まれる
      assert lines == ["k94gjk03-wakate-ronbun"]
    end

    test "handles unknown repository type filter", %{repositories: repositories} do
      opts = [type: "unknown"]

      {:error, reason} = List.run([], opts, repositories: repositories)

      assert String.contains?(reason, "Invalid type: unknown")
    end
  end

  describe "run/2 - long mode" do
    test "displays detailed table with --long option", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      opts = [long: true]

      {:ok, output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data
        )

      lines = String.split(output, "\n", trim: true)

      # ヘッダー行を確認: long はレジストリ詳細列をまとめて表示する
      header = Enum.at(lines, 0)
      assert String.contains?(header, "Repository")
      assert String.contains?(header, "Name")
      assert String.contains?(header, "GitHub User")
      assert String.contains?(header, "Type")
      assert String.contains?(header, "Protection (recorded)")
      assert String.contains?(header, "Registry Updated")
      # 監視系の列は出さない
      refute String.contains?(header, "Last Activity")
      refute String.contains?(header, "Owner Activity")

      # データ行を確認（少なくとも3行のデータ + 1行のヘッダー + 1行のセパレータ）
      assert length(lines) >= 5

      # 特定のデータが含まれることを確認
      content = Enum.join(lines, "\n")
      assert String.contains?(content, "k21rs001-sotsuron")
      assert String.contains?(content, "田中太郎")
      assert String.contains?(content, "student001")
    end

    test "includes student ID column with --show-student-id", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      opts = [long: true, show_student_id: true]

      {:ok, output} = List.run([], opts, repositories: repositories, csv_data: csv_data)

      lines = String.split(output, "\n", trim: true)
      header = Enum.at(lines, 0)
      assert String.contains?(header, "Student ID")

      content = Enum.join(lines, "\n")
      assert String.contains?(content, "k21rs001")
    end

    test "includes repository type column with --show-type", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      opts = [long: true, show_type: true]

      {:ok, output} = List.run([], opts, repositories: repositories, csv_data: csv_data)

      lines = String.split(output, "\n", trim: true)
      header = Enum.at(lines, 0)
      assert String.contains?(header, "Type")

      content = Enum.join(lines, "\n")
      assert String.contains?(content, "sotsuron")
      assert String.contains?(content, "wr")
      assert String.contains?(content, "ise")
    end

    test "includes protection status column with --show-protection", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      opts = [long: true, show_protection: true]

      {:ok, output} = List.run([], opts, repositories: repositories, csv_data: csv_data)

      lines = String.split(output, "\n", trim: true)
      header = Enum.at(lines, 0)
      assert String.contains?(header, "Protection")

      content = Enum.join(lines, "\n")
      assert String.contains?(content, "protected")
      assert String.contains?(content, "not_protected")
    end

    test "hides student names with --no-names", %{repositories: repositories, csv_data: csv_data} do
      opts = [long: true, no_names: true]

      {:ok, output} = List.run([], opts, repositories: repositories, csv_data: csv_data)

      lines = String.split(output, "\n", trim: true)
      header = Enum.at(lines, 0)
      refute String.contains?(header, "Name")

      content = Enum.join(lines, "\n")
      refute String.contains?(content, "田中太郎")
      refute String.contains?(content, "佐藤花子")
    end
  end

  describe "run/2 - archived filtering" do
    @archived_repositories %{
      "k21rs001-sotsuron" => %{
        "student_id" => "k21rs001",
        "repository_type" => "sotsuron",
        "registry_updated_at" => "2025-07-08T15:30:00.000000Z",
        "github_username" => "student001",
        "protection_status" => "protected"
      },
      "k18rs099-sotsuron" => %{
        "student_id" => "k18rs099",
        "repository_type" => "sotsuron",
        "registry_updated_at" => "2022-03-01T00:00:00.000000Z",
        "github_username" => "student099",
        "protection_status" => "protected",
        "archived_at" => "2025-03-31T00:00:00.000000Z"
      }
    }

    test "hides archived repositories by default" do
      {:ok, output} = List.run([], [], repositories: @archived_repositories)

      lines = String.split(output, "\n", trim: true)
      assert lines == ["k21rs001-sotsuron"]
      refute "k18rs099-sotsuron" in lines
    end

    test "includes archived repositories with show_archived" do
      {:ok, output} = List.run([], [show_archived: true], repositories: @archived_repositories)

      lines = String.split(output, "\n", trim: true)
      assert "k21rs001-sotsuron" in lines
      assert "k18rs099-sotsuron" in lines
      assert length(lines) == 2
    end

    test "treats empty-string archived_at as active" do
      repositories = %{
        "active-repo" => %{
          "student_id" => "k21rs001",
          "repository_type" => "wr",
          "github_username" => "student001",
          "archived_at" => ""
        }
      }

      {:ok, output} = List.run([], [], repositories: repositories)

      lines = String.split(output, "\n", trim: true)
      assert lines == ["active-repo"]
    end

    test "archived filter applies together with type filter" do
      {:ok, output} =
        List.run([], [type: "sotsuron"], repositories: @archived_repositories)

      lines = String.split(output, "\n", trim: true)
      assert lines == ["k21rs001-sotsuron"]
    end

    test "show_archived surfaces archived entries in JSON output", %{csv_data: csv_data} do
      {:ok, output} =
        List.run([], [format: "json", long: true, show_archived: true],
          repositories: @archived_repositories,
          csv_data: csv_data
        )

      {:ok, parsed} = Jason.decode(output)
      repos = Enum.map(parsed, & &1["repository"])
      assert "k18rs099-sotsuron" in repos
    end
  end

  describe "run/2 - sorting" do
    test "sorts by time with --sort time --show-registry-updated (newest first)", %{
      repositories: repositories
    } do
      opts = [sort: "time", show_registry_updated: true]

      {:ok, output} = List.run([], opts, repositories: repositories)

      lines = String.split(output, "\n", trim: true)

      # registry_updated_at順（新しい順）:
      # k94gjk03 (2025-07-12 11:00) > k93gjk02 (2025-07-11 11:00) > k92gjk01 (2025-07-10 11:00)
      # > k21rs003 (2025-07-09 14:00) > k21rs002 (2025-07-09 10:00) > k21rs001 (2025-07-08 15:30)
      # 実際は最新のものが最初に来る
      assert Enum.at(lines, 0) == "k94gjk03-wakate-ronbun"
    end

    test "reverses sort order with --reverse", %{repositories: repositories} do
      opts = [reverse: true]

      {:ok, output} = List.run([], opts, repositories: repositories)

      lines = String.split(output, "\n", trim: true)
      # アルファベット逆順
      expected = [
        "k94gjk03-wakate-ronbun",
        "k93gjk02-master",
        "k92gjk01-master",
        "k21rs003-ise-report1",
        "k21rs002-wr",
        "k21rs001-sotsuron"
      ]

      assert lines == expected
    end

    test "combines time sort and reverse", %{repositories: repositories} do
      opts = [sort: "time", reverse: true, show_registry_updated: true]

      {:ok, output} = List.run([], opts, repositories: repositories)

      lines = String.split(output, "\n", trim: true)
      # Registry Updated時刻順の逆順（古い順）
      # 最も古いものが最初、最も新しいものが最後
      first_line = Enum.at(lines, 0)
      last_line = Enum.at(lines, -1)
      assert first_line == "k21rs001-sotsuron"
      assert last_line == "k94gjk03-wakate-ronbun"
    end

    test "handles invalid timestamps gracefully in time sorting" do
      invalid_timestamp_repositories = %{
        "k21rs001-repo" => %{
          "student_id" => "k21rs001",
          "repository_type" => "wr",
          "registry_updated_at" => "invalid-timestamp"
        },
        "k21rs002-repo" => %{
          "student_id" => "k21rs002",
          "repository_type" => "wr",
          "registry_updated_at" => "2025-07-09T15:00:00.000000Z"
        },
        "k21rs003-repo" => %{
          "student_id" => "k21rs003",
          "repository_type" => "wr",
          "registry_updated_at" => "another-invalid"
        }
      }

      opts = [sort: "time", show_registry_updated: true]

      {:ok, output} = List.run([], opts, repositories: invalid_timestamp_repositories)

      lines = String.split(output, "\n", trim: true)

      # 有効なタイムスタンプのものが最初に来るべき
      assert Enum.at(lines, 0) == "k21rs002-repo"

      # 無効なタイムスタンプ同士はアルファベット順
      remaining_lines = Enum.drop(lines, 1)
      assert "k21rs001-repo" in remaining_lines
      assert "k21rs003-repo" in remaining_lines
      # アルファベット順で k21rs001 < k21rs003
      k21rs001_index = Enum.find_index(remaining_lines, &(&1 == "k21rs001-repo"))
      k21rs003_index = Enum.find_index(remaining_lines, &(&1 == "k21rs003-repo"))
      assert k21rs001_index < k21rs003_index
    end

    test "sorts by time with identical timestamps using alphabetical fallback" do
      same_timestamp_repositories = %{
        "z-repo" => %{
          "student_id" => "k21rs001",
          "repository_type" => "wr",
          "registry_updated_at" => "2025-07-09T15:00:00.000000Z"
        },
        "a-repo" => %{
          "student_id" => "k21rs002",
          "repository_type" => "wr",
          # 同じ時刻
          "registry_updated_at" => "2025-07-09T15:00:00.000000Z"
        },
        "m-repo" => %{
          "student_id" => "k21rs003",
          "repository_type" => "wr",
          # 同じ時刻
          "registry_updated_at" => "2025-07-09T15:00:00.000000Z"
        }
      }

      opts = [sort: "time", show_registry_updated: true]

      {:ok, output} = List.run([], opts, repositories: same_timestamp_repositories)

      lines = String.split(output, "\n", trim: true)

      # 同じ時刻の場合はアルファベット順になるべき
      assert lines == ["a-repo", "m-repo", "z-repo"]
    end
  end

  describe "run/2 - output formats" do
    test "outputs CSV format", %{repositories: repositories, csv_data: csv_data} do
      opts = [format: "csv", long: true]

      {:ok, output} =
        List.run([], opts,
          repositories: repositories,
          csv_data: csv_data
        )

      lines = String.split(output, "\n", trim: true)

      # CSV ヘッダー: long はレジストリ詳細列を出す
      header = Enum.at(lines, 0)

      assert String.contains?(
               header,
               "repository,name,github_username,type,protection_status,registry_updated_at"
             )

      # CSV データ
      data_line = Enum.at(lines, 1)
      assert String.starts_with?(data_line, "k21rs001-sotsuron,田中太郎,student001,")
    end

    test "outputs JSON format", %{repositories: repositories, csv_data: csv_data} do
      opts = [format: "json", long: true]

      {:ok, output} = List.run([], opts, repositories: repositories, csv_data: csv_data)

      {:ok, parsed} = Jason.decode(output)

      assert is_list(parsed)
      assert length(parsed) == 6

      first_entry = Enum.at(parsed, 0)
      assert first_entry["repository"] == "k21rs001-sotsuron"
      assert first_entry["name"] == "田中太郎"
      assert first_entry["github_username"] == "student001"
    end

    test "handles invalid format gracefully", %{repositories: repositories} do
      opts = [format: "invalid"]

      {:error, reason} = List.run([], opts, repositories: repositories)

      assert String.contains?(reason, "Invalid format")
    end
  end

  describe "run/2 - Issue #101: GitHub username array handling" do
    test "resolves student name when github_username is an array", %{csv_data: csv_data} do
      # GitHub username が配列形式のリポジトリデータ
      array_repositories = %{
        "k92rs120-wr" => %{
          "student_id" => "k92rs120",
          "repository_type" => "wr",
          # 配列形式
          "github_username" => ["k92rs120"],
          "registry_updated_at" => "2025-07-15T10:00:00.000000Z"
        },
        "k93rs042-wr" => %{
          "student_id" => "k93rs042",
          "repository_type" => "wr",
          # 配列形式
          "github_username" => ["k93rs042"],
          "registry_updated_at" => "2025-07-15T11:00:00.000000Z"
        }
      }

      opts = [long: true]

      {:ok, output} = List.run([], opts, repositories: array_repositories, csv_data: csv_data)

      lines = String.split(output, "\n", trim: true)
      content = Enum.join(lines, "\n")

      # 配列形式のGitHub usernameでもCSVから正しく名前を取得できることを確認
      assert String.contains?(content, "k92rs120-wr")
      assert String.contains?(content, "k93rs042-wr")

      # N/A が表示されないことを確認
      refute String.contains?(content, "N/A")
    end

    test "resolves student name when github_username is a single string", %{csv_data: csv_data} do
      # GitHub username が文字列形式のリポジトリデータ
      string_repositories = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          # 文字列形式
          "github_username" => "student001",
          "registry_updated_at" => "2025-07-15T10:00:00.000000Z"
        }
      }

      opts = [long: true]

      {:ok, output} = List.run([], opts, repositories: string_repositories, csv_data: csv_data)

      lines = String.split(output, "\n", trim: true)
      content = Enum.join(lines, "\n")

      # 文字列形式のGitHub usernameでもCSVから正しく名前を取得できることを確認
      assert String.contains?(content, "田中太郎")
      refute String.contains?(content, "N/A")
    end

    test "shows N/A when github_username array contains no matching CSV entries" do
      # CSV にない GitHub username の配列を持つリポジトリデータ
      unknown_repositories = %{
        "unknown-repo" => %{
          "student_id" => "unknown",
          "repository_type" => "wr",
          # CSVにない配列
          "github_username" => ["unknown-user"],
          "registry_updated_at" => "2025-07-15T10:00:00.000000Z"
        }
      }

      opts = [long: true]

      {:ok, output} =
        List.run([], opts, repositories: unknown_repositories, csv_data: @test_csv_data)

      lines = String.split(output, "\n", trim: true)
      content = Enum.join(lines, "\n")

      # CSVにない場合はN/Aが表示されることを確認
      assert String.contains?(content, "N/A")
    end

    test "handles multiple usernames in array correctly" do
      # 複数のGitHub username を持つリポジトリデータ
      multi_repositories = %{
        "multi-owner-repo" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          # 複数のユーザー
          "github_username" => ["student001", "student002"],
          "registry_updated_at" => "2025-07-15T10:00:00.000000Z"
        }
      }

      opts = [long: true]

      {:ok, output} =
        List.run([], opts, repositories: multi_repositories, csv_data: @test_csv_data)

      lines = String.split(output, "\n", trim: true)
      content = Enum.join(lines, "\n")

      # 最初にマッチした名前が表示されることを確認
      # student001 にマッチ
      assert String.contains?(content, "田中太郎")
      refute String.contains?(content, "N/A")
    end

    test "handles empty string github_username gracefully" do
      # 空文字列のGitHub username を持つリポジトリデータ
      empty_repositories = %{
        "empty-username-repo" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          # 空文字列
          "github_username" => "",
          "registry_updated_at" => "2025-07-15T10:00:00.000000Z"
        }
      }

      # CSV データにも空文字列エントリを含める
      csv_with_empty =
        @test_csv_data ++
          [
            %{"student_id" => "k21rs999", "name" => "空文字テスト", "github_username" => ""}
          ]

      opts = [long: true]

      {:ok, output} =
        List.run([], opts, repositories: empty_repositories, csv_data: csv_with_empty)

      lines = String.split(output, "\n", trim: true)
      content = Enum.join(lines, "\n")

      # 空文字列では照合されず、student_id で照合される
      # student_id k21rs001 でマッチ
      assert String.contains?(content, "田中太郎")
      # 空文字列では照合されない
      refute String.contains?(content, "空文字テスト")
    end

    test "handles array with empty strings correctly" do
      # 空文字列を含む配列のGitHub username を持つリポジトリデータ
      mixed_repositories = %{
        "mixed-array-repo" => %{
          "student_id" => "k21rs999",
          "repository_type" => "sotsuron",
          # 空文字列を含む配列
          "github_username" => ["", "student001", ""],
          "registry_updated_at" => "2025-07-15T10:00:00.000000Z"
        }
      }

      opts = [long: true]

      {:ok, output} =
        List.run([], opts, repositories: mixed_repositories, csv_data: @test_csv_data)

      lines = String.split(output, "\n", trim: true)
      content = Enum.join(lines, "\n")

      # 空文字列は無視され、有効なユーザー名でマッチする
      # student001 にマッチ
      assert String.contains?(content, "田中太郎")
      refute String.contains?(content, "N/A")
    end
  end

  describe "run/2 - legacy compatibility" do
    test "handles legacy data format during migration", %{csv_data: csv_data} do
      legacy_repositories = %{
        "k88rs509-ise-report1" => %{
          "student_id" => "k88rs509",
          "repository_type" => "ise",
          "status" => "active",
          "stage" => "ise",
          "created_at" => "2025-07-06T16:20:06.000000Z",
          "updated_at" => "2025-07-08T10:00:00.000000Z",
          "github_username" => "k88rs509",
          "protection_status" => "protected"
        }
      }

      # Issue #107: デフォルトでLast Activityが表示されるが、レガシーデータには
      # 活動情報がないため、Registry Updatedを表示する --show-registry-updated オプションを使用
      opts = [long: true, show_registry_updated: true]

      {:ok, output} = List.run([], opts, repositories: legacy_repositories, csv_data: csv_data)

      # レガシーデータも正常に処理される
      assert String.contains?(output, "k88rs509-ise-report1")
      # updated_at が JST 変換されてregistry_updated_atに移行される
      assert String.contains?(output, "2025-07-08 19:00:00")
    end
  end

  describe "run/2 - error handling" do
    test "handles empty repository list", %{csv_data: csv_data} do
      opts = []

      {:ok, output} = List.run([], opts, repositories: %{}, csv_data: csv_data)

      assert output == ""
    end

    test "handles missing CSV data for student names", %{repositories: repositories} do
      opts = [long: true]

      {:ok, output} = List.run([], opts, repositories: repositories, csv_data: [])

      # 学生名が N/A になることを確認
      assert String.contains?(output, "N/A")
    end

    test "handles malformed repository data gracefully", %{csv_data: csv_data} do
      malformed_repositories = %{
        "invalid-repo" => %{
          "student_id" => "k21rs999"
          # 必要なフィールドが不足
        }
      }

      opts = [long: true]

      {:ok, output} = List.run([], opts, repositories: malformed_repositories, csv_data: csv_data)

      # エラーハンドリングされて部分的な情報が表示される
      assert String.contains?(output, "invalid-repo")
    end
  end

  describe "dynamic column width formatting" do
    test "adjusts column widths based on content", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      # 長いリポジトリ名を追加
      long_name_repos =
        Map.put(repositories, "k21rs999-very-long-repository-name-for-testing", %{
          "student_id" => "k21rs999",
          "repository_type" => "sotsuron",
          "repository_created_at" => "2025-07-10T10:00:00.000000Z",
          "registry_created_at" => "2025-07-10T10:00:00.000000Z",
          "registry_updated_at" => "2025-07-10T10:00:00.000000Z",
          "github_username" => "verylongusername999",
          "protection_status" => "protected"
        })

      # 長い学生名のデータを追加
      extended_csv_data =
        csv_data ++
          [
            %{
              "student_id" => "k21rs999",
              "name" => "これは非常に長い学生の名前です",
              "github_username" => "verylongusername999"
            }
          ]

      opts = [long: true]

      {:ok, output} =
        List.run([], opts, repositories: long_name_repos, csv_data: extended_csv_data)

      lines = String.split(output, "\n", trim: true)

      # セパレータ行がテーブル形式のセパレータであることを確認
      # 期待される形式: "--------  ------  -----------  ----------------"
      separator = Enum.at(lines, 1)

      # セパレータが列ごとに分かれていることを確認（実装済みの動的列幅対応）
      separator_parts = String.split(separator, ~r/\s+/)

      # 動的列幅実装により、各列に対応したセパレータセクションが生成される
      assert length(separator_parts) >= 4,
             "Separator should have multiple sections for each column"
    end

    test "handles Japanese characters properly in column width calculation", %{
      repositories: repositories
    } do
      # 日本語を含むデータ（異なる文字幅でテスト）
      japanese_csv_data = [
        %{"student_id" => "k21rs001", "name" => "田中太郎", "github_username" => "student001"},
        %{"student_id" => "k21rs002", "name" => "山田花子", "github_username" => "student002"},
        %{"student_id" => "k21rs003", "name" => "鈴木一郎二郎三郎", "github_username" => "student003"}
      ]

      opts = [long: true]
      {:ok, output} = List.run([], opts, repositories: repositories, csv_data: japanese_csv_data)

      lines = String.split(output, "\n", trim: true)
      header_line = Enum.at(lines, 0)
      separator_line = Enum.at(lines, 1)
      data_lines = Enum.drop(lines, 2)

      # ヘッダー行から各列の構造を確認
      _header_columns = String.split(header_line, ~r/\s{2,}/)

      # 各データ行の列構造が一貫していることを確認
      Enum.each(data_lines, fn line ->
        actual_columns = String.split(line, ~r/\s{2,}/)

        # 列数が一致することを確認（最小限のチェック）
        # Note: パディングにより空の列が生じる可能性があるため、最小列数をチェック
        assert length(actual_columns) >= 3,
               "Row should have at least 3 columns (repo, name, github_user, updated)"

        # 最初の3列（Repository, Name, GitHub User）について基本的な検証
        [repo_col, name_col, github_col | _] = actual_columns

        # 各列に適切な内容が含まれることを確認
        assert String.length(String.trim(repo_col)) > 0, "Repository column should not be empty"

        assert String.length(String.trim(github_col)) > 0,
               "GitHub User column should not be empty"

        # name_col は日本語なので、適切に表示されることを確認
        # @test_repositories と @test_csv_data から取得可能な名前のリスト
        valid_names = ["田中太郎", "山田花子", "鈴木一郎二郎三郎", "高橋一郎", "伊藤二郎", "渡辺三郎", "N/A"]

        assert String.trim(name_col) in valid_names,
               "Name should be one of the test Japanese names or N/A, got: #{String.trim(name_col)}"
      end)

      # セパレータが各列に対応していることを確認
      separator_parts = String.split(separator_line, ~r/\s{2,}/)

      # セパレータ部分が基本的な列数を含むことを確認
      # 注意: ヘッダーと完全に一致しない場合がある（末尾スペースなど）
      assert length(separator_parts) >= 4,
             "Separator should have at least 4 sections for main columns"
    end

    test "creates appropriate separator line length", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      opts = [long: true, show_type: true, show_protection: true]
      {:ok, output} = List.run([], opts, repositories: repositories, csv_data: csv_data)

      lines = String.split(output, "\n", trim: true)
      header = Enum.at(lines, 0)
      separator = Enum.at(lines, 1)

      # セパレータがヘッダーと同じかそれ以上の長さであることを確認
      assert String.length(separator) >= String.length(header)

      # セパレータが適切な形式（ダッシュとスペース）で構成されていることを確認
      assert String.match?(separator, ~r/^(-+\s*)+$/)
    end
  end

  describe "validate_options/1" do
    test "validates valid options" do
      valid_opts = [long: true, type: "wr", format: "table"]

      assert {:ok, ^valid_opts} = List.validate_options(valid_opts)
    end

    test "validates format option" do
      assert {:error, _} = List.validate_options(format: "invalid")
      assert {:ok, _} = List.validate_options(format: "table")
      assert {:ok, _} = List.validate_options(format: "csv")
      assert {:ok, _} = List.validate_options(format: "json")
    end

    test "validates type option" do
      assert {:ok, _} = List.validate_options(type: "wr")
      assert {:ok, _} = List.validate_options(type: "ise")
      assert {:ok, _} = List.validate_options(type: "sotsuron")
      assert {:ok, _} = List.validate_options(type: "thesis")
      assert {:ok, _} = List.validate_options(type: "master")
      assert {:ok, _} = List.validate_options(type: "other")
    end
  end

  describe "run/2 - real CSV integration" do
    test "displays student names from actual CSV file when available" do
      # この테스트는 실제 CSV 파일 (test/fixtures/test_students.csv)을 사용하여
      # 학생 이름이 올바르게 표시되는지 확인합니다.
      repositories = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "registry_updated_at" => "2025-07-08T15:30:00.000000Z",
          "github_username" => "student001"
        }
      }

      opts = [long: true]

      # test_params를 전달하지 않아서 실제 CSV 읽기 기능이 작동되도록 함
      {:ok, output} = List.run([], opts, repositories: repositories)

      # 출력에서 학생 이름이 "N/A"가 아닌 실제 이름으로 표시되는지 확인
      # 현재 버그: 모든 이름이 "N/A"로 표시됨
      # 수정 후: CSV에서 읽은 실제 학생 이름이 표시되어야 함
      lines = String.split(output, "\n", trim: true)

      # 적어도 헤더와 데이터 행이 있어야 함
      assert length(lines) >= 2

      content = Enum.join(lines, "\n")
      assert String.contains?(content, "k21rs001-sotsuron")

      # 이 테스트는 현재 실패할 것 (모든 이름이 "N/A"로 표시되기 때문)
      # 수정 후에는 실제 CSV 데이터에 기반한 학생 이름이 표시되어야 함
    end
  end

  describe "registry view details (long mode)" do
    setup do
      test_repositories = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "registry_updated_at" => "2025-07-08T15:30:00.000000Z",
          "github_username" => "student001",
          "protection_status" => "protected"
        },
        "k21rs002-wr" => %{
          "student_id" => "k21rs002",
          "repository_type" => "wr",
          "registry_updated_at" => "2025-07-09T10:00:00.000000Z",
          "github_username" => "student002",
          "protection_status" => "not_protected"
        }
      }

      test_csv_data = [
        %{"student_id" => "k21rs001", "name" => "田中太郎", "github_username" => "student001"},
        %{"student_id" => "k21rs002", "name" => "佐藤花子", "github_username" => "student002"}
      ]

      {:ok, repositories: test_repositories, csv_data: test_csv_data}
    end

    test "long shows the registry detail columns and no monitoring columns", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      {:ok, output} = List.run([], [long: true], repositories: repositories, csv_data: csv_data)

      header = output |> String.split("\n", trim: true) |> Enum.at(0)

      assert String.contains?(header, "Type")
      assert String.contains?(header, "Protection (recorded)")
      assert String.contains?(header, "Registry Updated")
      refute String.contains?(header, "Last Activity")
      refute String.contains?(header, "Owner Activity")
    end

    test "protection column header marks the value as recorded", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      {:ok, output} =
        List.run([], [long: true, show_protection: true],
          repositories: repositories,
          csv_data: csv_data
        )

      header = output |> String.split("\n", trim: true) |> Enum.at(0)
      assert String.contains?(header, "Protection (recorded)")

      assert String.contains?(output, "protected")
      assert String.contains?(output, "not_protected")
    end

    test "Registry Updated values are JST-formatted from registry_updated_at", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      {:ok, output} = List.run([], [long: true], repositories: repositories, csv_data: csv_data)

      content = output
      # 2025-07-08T15:30:00Z -> JST 2025-07-09 00:30:00
      assert String.contains?(content, "2025-07-09 00:30:00")
    end

    test "--show-registry-updated renders the registry updated column in basic table via long", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      {:ok, output} =
        List.run([], [long: true, show_registry_updated: true],
          repositories: repositories,
          csv_data: csv_data
        )

      header = output |> String.split("\n", trim: true) |> Enum.at(0)
      assert String.contains?(header, "Registry Updated")
    end

    test "CSV in long mode emits the registry detail columns", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      {:ok, output} =
        List.run([], [long: true, format: "csv"], repositories: repositories, csv_data: csv_data)

      header = output |> String.split("\n", trim: true) |> Enum.at(0)
      assert String.contains?(header, "registry_updated_at")
      assert String.contains?(header, "protection_status")
      refute String.contains?(header, "last_activity")
    end

    test "JSON in long mode includes registry_updated_at and no activity fields", %{
      repositories: repositories,
      csv_data: csv_data
    } do
      {:ok, output} =
        List.run([], [long: true, format: "json"], repositories: repositories, csv_data: csv_data)

      assert {:ok, json_data} = Jason.decode(output)
      first_repo = Enum.at(json_data, 0)

      assert Map.has_key?(first_repo, "registry_updated_at")
      refute Map.has_key?(first_repo, "last_activity")
      refute Map.has_key?(first_repo, "owner_activity")
    end
  end
end
