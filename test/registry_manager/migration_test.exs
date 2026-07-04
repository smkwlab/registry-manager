defmodule RegistryManager.MigrationTest do
  use ExUnit.Case, async: false
  alias RegistryManager.Migration

  describe "v4 format detection" do
    test "identifies v4 format with created_at and registry_updated_at" do
      v4_entry = %{
        "student_id" => "k21rs001",
        "repository_type" => "sotsuron",
        "created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_updated_at" => "2025-07-08T06:51:39.835808Z",
        "github_username" => "student001"
      }

      assert Migration.is_v4_format?(v4_entry)
    end

    test "identifies v1 format with status and stage" do
      v1_entry = %{
        "student_id" => "k19rs999",
        "repository_type" => "sotsuron",
        "status" => "completed",
        "stage" => "sotsuron",
        "updated_at" => "2025-07-07 16:44:44 UTC",
        "github_username" => "k19rs999"
      }

      refute Migration.is_v4_format?(v1_entry)
    end

    test "identifies mixed format as v1 (has legacy fields)" do
      mixed_entry = %{
        "student_id" => "k21rs001",
        "repository_type" => "sotsuron",
        "created_at" => "2025-07-08T06:51:39.835808Z",
        # Legacy field
        "status" => "active",
        "updated_at" => "2025-07-07 16:44:44 UTC"
      }

      refute Migration.is_v4_format?(mixed_entry)
    end
  end

  describe "single entry migration" do
    test "migrates v1 entry with all fields" do
      v1_entry = %{
        "student_id" => "k19rs999",
        "repository_type" => "thesis",
        "status" => "completed",
        "stage" => "thesis",
        "updated_at" => "2025-07-07 16:44:44 UTC",
        "github_username" => "k19rs999",
        "repository_created_at" => "2025-07-01 10:00:00 UTC"
      }

      {:ok, migrated} = Migration.migrate_single_entry("k19rs999-sotsuron", v1_entry)

      assert migrated["student_id"] == "k19rs999"
      # normalized from "thesis"
      assert migrated["repository_type"] == "sotsuron"
      assert migrated["github_username"] == "k19rs999"
      assert Map.has_key?(migrated, "created_at")
      assert Map.has_key?(migrated, "registry_updated_at")

      # Legacy fields should be removed
      refute Map.has_key?(migrated, "status")
      refute Map.has_key?(migrated, "stage")
      refute Map.has_key?(migrated, "updated_at")
      refute Map.has_key?(migrated, "repository_created_at")
    end

    test "normalizes repository types" do
      v1_entry = %{
        "student_id" => "k88rs001",
        "repository_type" => "ise",
        "status" => "active"
      }

      {:ok, migrated} = Migration.migrate_single_entry("k88rs001-ise", v1_entry)

      assert migrated["repository_type"] == "ise-report"
    end

    test "keeps v4 entries unchanged" do
      v4_entry = %{
        "student_id" => "k21rs001",
        "repository_type" => "wr",
        "created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_updated_at" => "2025-07-08T06:51:39.835808Z",
        "github_username" => "student001"
      }

      {:ok, migrated} = Migration.migrate_single_entry("k21rs001-wr", v4_entry)

      assert migrated == v4_entry
    end

    test "handles missing required fields" do
      incomplete_entry = %{
        "repository_type" => "sotsuron"
        # Missing student_id
      }

      {:error, reason} = Migration.migrate_single_entry("invalid-repo", incomplete_entry)
      assert reason =~ "Missing required fields"
    end

    test "handles missing optional fields gracefully" do
      minimal_entry = %{
        "student_id" => "k21rs001",
        "repository_type" => "wr"
        # No github_username, no timestamps
      }

      {:ok, migrated} = Migration.migrate_single_entry("k21rs001-wr", minimal_entry)

      assert migrated["student_id"] == "k21rs001"
      assert migrated["repository_type"] == "wr"
      assert Map.has_key?(migrated, "created_at")
      assert Map.has_key?(migrated, "registry_updated_at")
      refute Map.has_key?(migrated, "github_username")
    end
  end

  describe "timestamp normalization" do
    test "converts UTC format to ISO8601" do
      v1_entry = %{
        "student_id" => "k19rs999",
        "repository_type" => "sotsuron",
        "updated_at" => "2025-07-07 16:44:44 UTC"
      }

      {:ok, migrated} = Migration.migrate_single_entry("k19rs999-sotsuron", v1_entry)

      # Should convert to ISO8601 format (with optional milliseconds)
      assert migrated["registry_updated_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/
    end

    test "preserves valid ISO8601 timestamps" do
      v1_entry = %{
        "student_id" => "k91rs044",
        "repository_type" => "wr",
        "repository_created_at" => "2025-07-08T06:51:39.835808Z"
      }

      {:ok, migrated} = Migration.migrate_single_entry("k91rs044-wr", v1_entry)

      assert migrated["created_at"] == "2025-07-08T06:51:39.835808Z"
    end

    test "uses current timestamp for invalid dates" do
      v1_entry = %{
        "student_id" => "k21rs001",
        "repository_type" => "wr",
        "updated_at" => "invalid-date"
      }

      {:ok, migrated} = Migration.migrate_single_entry("k21rs001-wr", v1_entry)

      # Should use current timestamp (with optional milliseconds)
      assert migrated["registry_updated_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/
    end
  end

  describe "bulk migration" do
    test "migrates mixed v1/v4 registry data" do
      registry_data = %{
        "k91rs044-wr" => %{
          "created_at" => "2025-07-08T06:51:39.835808Z",
          "github_username" => "mockuser3",
          "registry_updated_at" => "2025-07-08T06:51:39.835808Z",
          "repository_type" => "wr",
          "student_id" => "k91rs044"
        },
        "k19rs999-sotsuron" => %{
          "repository_type" => "sotsuron",
          "stage" => "sotsuron",
          "status" => "completed",
          "student_id" => "k19rs999",
          "updated_at" => "2025-07-07 16:44:44 UTC",
          "github_username" => "k19rs999"
        }
      }

      {:ok, {migrated_data, stats}} = Migration.migrate_to_v4(registry_data)

      assert stats.total_entries == 2
      assert stats.already_v4 == 1
      assert stats.migrated == 1
      assert stats.errors == []

      # v4 entry should remain unchanged
      assert migrated_data["k91rs044-wr"]["created_at"] == "2025-07-08T06:51:39.835808Z"

      # v1 entry should be migrated
      migrated_entry = migrated_data["k19rs999-sotsuron"]
      assert migrated_entry["student_id"] == "k19rs999"
      assert migrated_entry["repository_type"] == "sotsuron"
      refute Map.has_key?(migrated_entry, "status")
      refute Map.has_key?(migrated_entry, "stage")
      assert Map.has_key?(migrated_entry, "created_at")
      assert Map.has_key?(migrated_entry, "registry_updated_at")
    end

    test "handles migration errors gracefully" do
      registry_data = %{
        "valid-repo" => %{
          "student_id" => "k21rs001",
          "repository_type" => "wr",
          "status" => "active"
        },
        "invalid-repo" => %{
          "repository_type" => "wr"
          # Missing student_id
        }
      }

      {:ok, {migrated_data, stats}} = Migration.migrate_to_v4(registry_data)

      assert stats.total_entries == 2
      assert stats.migrated == 1
      assert stats.already_v4 == 0
      assert length(stats.errors) == 1

      # Valid entry should be migrated
      assert Map.has_key?(migrated_data["valid-repo"], "created_at")

      # Invalid entry should be kept as-is
      assert migrated_data["invalid-repo"] == registry_data["invalid-repo"]

      # Error should be recorded
      error = List.first(stats.errors)
      assert error.repo_name == "invalid-repo"
      assert error.reason =~ "Missing required fields"
    end
  end

  describe "migration report generation" do
    test "generates comprehensive migration report" do
      stats = %{
        total_entries: 5,
        already_v4: 2,
        migrated: 2,
        errors: [
          %{repo_name: "invalid-repo", reason: "Missing student_id"}
        ]
      }

      report = Migration.generate_migration_report(stats)

      assert report =~ "Total entries:        5"
      assert report =~ "Already v4 format:    2"
      assert report =~ "Require migration:    2"
      assert report =~ "Migration errors:     1"
      assert report =~ "invalid-repo: Missing student_id"
      assert report =~ "2 entries will be migrated"
    end

    test "handles no migration needed case" do
      stats = %{
        total_entries: 3,
        already_v4: 3,
        migrated: 0,
        errors: []
      }

      report = Migration.generate_migration_report(stats)

      assert report =~ "Already v4 format:    3"
      assert report =~ "Require migration:    0"
      assert report =~ "No migration errors detected"
      assert report =~ "All entries are already in v4 format"
    end
  end

  describe "dry run migration" do
    test "performs analysis without changing data" do
      registry_data = %{
        "k21rs001-wr" => %{
          "student_id" => "k21rs001",
          "repository_type" => "wr",
          "status" => "active"
        }
      }

      {:ok, report} = Migration.dry_run_migration(registry_data)

      assert report =~ "Migration Analysis Report"
      assert report =~ "Total entries:        1"
      assert report =~ "Require migration:    1"
    end
  end
end
