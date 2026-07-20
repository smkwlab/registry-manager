defmodule RegistryManager.Commands.ValidateTest do
  use ExUnit.Case

  alias RegistryManager.Commands.Validate

  # テスト用のモックデータ
  @valid_repositories %{
    "k21rs001-sotsuron" => %{
      "student_id" => "k21rs001",
      "repository_type" => "sotsuron",
      "created_at" => "2025-07-08T06:51:39.835808Z",
      "registry_updated_at" => "2025-07-08T15:30:00.000000Z",
      "github_username" => "student001",
      "protection_status" => "protected",
      "review_flow" => true
    },
    "k21rs002-wr" => %{
      "student_id" => "k21rs002",
      "repository_type" => "wr",
      "created_at" => "2025-07-07T10:20:00.000000Z",
      "registry_updated_at" => "2025-07-09T10:00:00.000000Z",
      "github_username" => "student002",
      "protection_status" => "not_protected",
      "review_flow" => false
    }
  }

  @mixed_repositories %{
    # 新形式（正しい）
    "k21rs001-sotsuron" => %{
      "student_id" => "k21rs001",
      "repository_type" => "sotsuron",
      "created_at" => "2025-07-08T06:51:39.835808Z",
      "registry_updated_at" => "2025-07-08T15:30:00.000000Z",
      "github_username" => "student001",
      "review_flow" => true
    },
    # レガシー形式
    "k88rs509-ise-report1" => %{
      "student_id" => "k88rs509",
      "repository_type" => "ise",
      "status" => "active",
      "stage" => "ise",
      "created_at" => "2025-07-06T16:20:06.000000Z",
      "updated_at" => "2025-07-08T10:00:00.000000Z",
      "github_username" => "k88rs509",
      "review_flow" => true
    },
    # 不正な形式（必須フィールド不足）
    "k21rs003-invalid" => %{
      "student_id" => "k21rs003"
      # repository_type が不足
    }
  }

  @invalid_repositories %{
    # 不正な学生ID形式
    "invalid-id-repo" => %{
      "student_id" => "invalid123",
      "repository_type" => "sotsuron",
      "created_at" => "2025-07-08T06:51:39.835808Z"
    },
    # リポジトリ名と学生IDの不一致
    "k21rs001-sotsuron" => %{
      # 不一致
      "student_id" => "k21rs002",
      "repository_type" => "sotsuron",
      "created_at" => "2025-07-08T06:51:39.835808Z"
    },
    # 不正なリポジトリタイプ
    "k21rs003-unknown" => %{
      "student_id" => "k21rs003",
      "repository_type" => "unknown_type",
      "created_at" => "2025-07-08T06:51:39.835808Z"
    }
  }

  describe "run/3 - basic validation" do
    test "validates all entries successfully for valid data" do
      opts = []

      {:ok, output} = Validate.run([], opts, repositories: @valid_repositories)

      assert String.contains?(output, "Validation Report")
      assert String.contains?(output, "Total entries: 2")
      assert String.contains?(output, "Valid entries: 2")
      assert String.contains?(output, "Invalid entries: 0")
      assert String.contains?(output, "Legacy entries: 0")
      assert String.contains?(output, "✅ All entries are valid")
    end

    test "detects invalid entries in mixed data" do
      opts = []

      {:ok, output} = Validate.run([], opts, repositories: @mixed_repositories)

      assert String.contains?(output, "Validation Report")
      assert String.contains?(output, "Total entries: 3")
      assert String.contains?(output, "Valid entries: 1")
      assert String.contains?(output, "Invalid entries: 1")
      assert String.contains?(output, "Legacy entries: 1")
      assert String.contains?(output, "❌ Multiple validation errors found")
    end

    test "reports all errors for invalid data" do
      opts = []

      {:ok, output} = Validate.run([], opts, repositories: @invalid_repositories)

      assert String.contains?(output, "Validation Report")
      assert String.contains?(output, "Invalid entries: 3")
      assert String.contains?(output, "❌ Multiple validation errors found")
      assert String.contains?(output, "不正な学生ID形式")
      assert String.contains?(output, "リポジトリ名と学生IDが一致しません")
      assert String.contains?(output, "不正なリポジトリタイプ")
    end
  end

  describe "run/3 - verbose mode" do
    test "shows detailed information in verbose mode" do
      opts = [verbose: true]

      # Verbose モードでは IO.puts で標準出力に情報が表示されるため、
      # 戻り値のoutputには含まれない。代わりに通常の validation report が返される
      {:ok, output} = Validate.run([], opts, repositories: @mixed_repositories)

      # Verbose出力は IO.puts で別途表示される
      # 戻り値は通常のレポート形式
      assert String.contains?(output, "Validation Report")
      assert String.contains?(output, "Total entries: 3")
    end

    test "shows detailed validation in verbose mode" do
      opts = [verbose: true]

      {:ok, output} = Validate.run([], opts, repositories: @valid_repositories)

      # verbose モードでは詳細な検証情報が IO.puts で表示される
      # 戻り値は通常のレポート形式
      assert String.contains?(output, "Validation Report")
      assert String.contains?(output, "✅ All entries are valid")
    end
  end

  describe "run/3 - specific repository validation" do
    test "validates specific repository when name provided" do
      opts = []

      {:ok, output} = Validate.run(["k21rs001-sotsuron"], opts, repositories: @valid_repositories)

      assert String.contains?(output, "Validation Report for k21rs001-sotsuron")
      assert String.contains?(output, "✅ Entry is valid")
      assert String.contains?(output, "Student ID: k21rs001")
      assert String.contains?(output, "Repository Type: sotsuron")
    end

    test "reports error for non-existent repository" do
      opts = []

      {:error, reason} = Validate.run(["non-existent"], opts, repositories: @valid_repositories)

      assert reason == "Repository not found: non-existent"
    end
  end

  describe "run/3 - output formats" do
    test "outputs validation results in JSON format" do
      opts = [format: "json"]

      {:ok, output} = Validate.run([], opts, repositories: @mixed_repositories)

      {:ok, parsed} = Jason.decode(output)

      assert is_map(parsed)
      assert parsed["total_entries"] == 3
      assert parsed["valid_entries"] == 1
      assert parsed["invalid_entries"] == 1
      assert length(parsed["legacy_details"]) == 1
      assert is_list(parsed["errors"])
      assert is_list(parsed["legacy_details"])
    end

    test "outputs validation results in CSV format" do
      opts = [format: "csv"]

      {:ok, output} = Validate.run([], opts, repositories: @mixed_repositories)

      lines = String.split(output, "\n", trim: true)
      header = Enum.at(lines, 0)

      assert String.contains?(header, "repository,status,issues")
      assert Enum.any?(lines, &String.contains?(&1, "k21rs001-sotsuron,valid,"))
      assert Enum.any?(lines, &String.contains?(&1, "k88rs509-ise-report1,legacy,"))
      assert Enum.any?(lines, &String.contains?(&1, "k21rs003-invalid,invalid,"))
    end
  end

  describe "run/3 - timestamp validation" do
    test "accepts the current schema (created_at + registry_updated_at, fractional seconds ok)" do
      repo_with_timestamps = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "created_at" => "2025-07-08T06:51:39.835808Z",
          "registry_updated_at" => "2025-07-08T15:30:00.000000Z",
          "review_flow" => true
        }
      }

      opts = []

      {:ok, output} = Validate.run([], opts, repositories: repo_with_timestamps)

      assert String.contains?(output, "Valid entries: 1")
    end

    test "accepts a partial set of timestamp fields (each field is optional)" do
      repos = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "created_at" => "2025-07-08T06:51:39.835808Z",
          "review_flow" => true
        },
        "k21rs002-wr" => %{
          "student_id" => "k21rs002",
          "repository_type" => "wr",
          "registry_updated_at" => "2025-07-08T15:30:00.000000Z",
          "review_flow" => false
        }
      }

      {:ok, output} = Validate.run([], [], repositories: repos)

      assert String.contains?(output, "Valid entries: 2")
      assert String.contains?(output, "Invalid entries: 0")
    end

    test "rejects entries with no timestamp fields" do
      repos = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron"
        }
      }

      {:ok, output} = Validate.run([], [], repositories: repos)

      assert String.contains?(output, "Invalid entries: 1")
      assert String.contains?(output, "No timestamp fields found")
    end

    test "warns when only the legacy updated_at field is present" do
      repos = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "updated_at" => "2025-07-08 10:00:00 UTC",
          "review_flow" => true
        }
      }

      {:ok, output} = Validate.run([], [], repositories: repos)

      assert String.contains?(output, "Legacy entries: 1")
      assert String.contains?(output, "Legacy updated_at field detected")
    end

    test "warns on the legacy updated_at field" do
      repos = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "created_at" => "2025-07-08T06:51:39.835808Z",
          "registry_updated_at" => "2025-07-08T15:30:00.000000Z",
          "updated_at" => "2025-07-08 10:00:00 UTC",
          "review_flow" => true
        }
      }

      {:ok, output} = Validate.run([], [], repositories: repos)

      assert String.contains?(output, "Legacy entries: 1")
      assert String.contains?(output, "Legacy updated_at field detected")
    end

    test "validates timestamp format correctness" do
      repo_invalid_timestamp = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "created_at" => "invalid-timestamp",
          "registry_updated_at" => "2025-07-08T15:30:00.000000Z"
        }
      }

      opts = []

      {:ok, output} = Validate.run([], opts, repositories: repo_invalid_timestamp)

      assert String.contains?(output, "Invalid entries: 1")
      assert String.contains?(output, "Invalid timestamp format")
    end
  end

  describe "run/3 - archived entries" do
    test "skips validation for archived entries and reports the count" do
      repos = %{
        # 命名規約違反だが archived → 検証対象外
        "legacyname-wr" => %{
          "student_id" => "k20rs085",
          "repository_type" => "wr",
          "created_at" => "2020-07-08T06:51:39.835808Z",
          "review_flow" => false,
          "archived_at" => "2026-07-20T04:40:00Z"
        },
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "created_at" => "2025-07-08T06:51:39.835808Z",
          "review_flow" => true
        }
      }

      {:ok, output} = Validate.run([], [], repositories: repos)

      assert String.contains?(output, "Total entries: 2")
      assert String.contains?(output, "Valid entries: 1")
      assert String.contains?(output, "Invalid entries: 0")
      assert String.contains?(output, "Archived entries: 1")
      refute String.contains?(output, "リポジトリ名と学生IDが一致しません")
    end

    test "includes archived_entries in JSON output" do
      repos = %{
        "legacyname-wr" => %{
          "student_id" => "k20rs085",
          "repository_type" => "wr",
          "created_at" => "2020-07-08T06:51:39.835808Z",
          "archived_at" => "2026-07-20T04:40:00Z"
        }
      }

      {:ok, output} = Validate.run([], [format: "json"], repositories: repos)
      {:ok, parsed} = Jason.decode(output)

      assert parsed["archived_entries"] == 1
      assert parsed["invalid_entries"] == 0
    end

    test "reports an archived entry as skipped in single-repository mode" do
      repos = %{
        "legacyname-wr" => %{
          "student_id" => "k20rs085",
          "repository_type" => "wr",
          "created_at" => "2020-07-08T06:51:39.835808Z",
          "archived_at" => "2026-07-20T04:40:00Z"
        }
      }

      {:ok, output} = Validate.run(["legacyname-wr"], [], repositories: repos)

      assert String.contains?(output, "archived")
    end
  end

  describe "run/3 - review_flow validation" do
    test "rejects entries without review_flow" do
      repos = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "created_at" => "2025-07-08T06:51:39.835808Z"
        }
      }

      {:ok, output} = Validate.run([], [], repositories: repos)

      assert String.contains?(output, "Invalid entries: 1")
      assert String.contains?(output, "Missing review_flow field")
    end

    test "rejects non-boolean review_flow values" do
      repos = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "created_at" => "2025-07-08T06:51:39.835808Z",
          "review_flow" => "true"
        }
      }

      {:ok, output} = Validate.run([], [], repositories: repos)

      assert String.contains?(output, "Invalid entries: 1")
      assert String.contains?(output, "Invalid review_flow")
    end

    test "accepts poster entries with review_flow" do
      repos = %{
        "k21rs001-jsai2026-poster" => %{
          "student_id" => "k21rs001",
          "repository_type" => "poster",
          "created_at" => "2025-07-08T06:51:39.835808Z",
          "review_flow" => true
        }
      }

      {:ok, output} = Validate.run([], [], repositories: repos)

      assert String.contains?(output, "Valid entries: 1")
      assert String.contains?(output, "Invalid entries: 0")
    end
  end

  describe "run/3 - protection status validation" do
    test "validates protection status values" do
      repo_invalid_protection = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "created_at" => "2025-07-08T06:51:39.835808Z",
          "registry_updated_at" => "2025-07-08T15:30:00.000000Z",
          "protection_status" => "invalid_status"
        }
      }

      opts = []

      {:ok, output} = Validate.run([], opts, repositories: repo_invalid_protection)

      assert String.contains?(output, "Invalid entries: 1")
      assert String.contains?(output, "Invalid protection status")
    end
  end

  describe "run/3 - summary statistics" do
    test "provides summary statistics for large datasets" do
      # 大量のテストデータを生成
      large_dataset =
        1..100
        |> Enum.map(fn i ->
          student_id = "k21rs#{String.pad_leading(Integer.to_string(i), 3, "0")}"
          repo_name = "#{student_id}-sotsuron"

          entry =
            if rem(i, 10) == 0 do
              # 10個に1個は不正なデータ
              %{"student_id" => student_id}
            else
              %{
                "student_id" => student_id,
                "repository_type" => "sotsuron",
                "created_at" => "2025-07-08T06:51:39.835808Z",
                "registry_updated_at" => "2025-07-08T15:30:00.000000Z",
                "review_flow" => true
              }
            end

          {repo_name, entry}
        end)
        |> Enum.into(%{})

      opts = []

      {:ok, output} = Validate.run([], opts, repositories: large_dataset)

      assert String.contains?(output, "Total entries: 100")
      assert String.contains?(output, "Valid entries: 90")
      assert String.contains?(output, "Invalid entries: 10")
    end
  end
end
