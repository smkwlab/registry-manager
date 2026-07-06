defmodule RegistryManager.TimestampManagerTest do
  use ExUnit.Case

  alias RegistryManager.TimestampManager

  describe "current_utc_time/0" do
    test "returns current UTC datetime" do
      time = TimestampManager.current_utc_time()

      assert %DateTime{} = time
      assert time.time_zone == "Etc/UTC"

      # 現在時刻との差が1秒以内であることを確認
      now = DateTime.utc_now()
      diff = DateTime.diff(time, now, :second)
      assert abs(diff) <= 1
    end
  end

  describe "format_for_display/1" do
    test "formats UTC datetime to JST without timezone suffix" do
      # UTC時刻を作成
      utc_time = ~U[2025-07-09 10:30:00.000Z]

      formatted = TimestampManager.format_for_display(utc_time)

      # JST（UTC+9）に変換されて、時刻のみ表示
      assert formatted == "2025-07-09 19:30:00"
    end

    test "handles different UTC times correctly" do
      test_cases = [
        {~U[2025-01-01 00:00:00.000Z], "2025-01-01 09:00:00"},
        {~U[2025-12-31 23:59:59.000Z], "2026-01-01 08:59:59"},
        {~U[2025-07-15 12:00:00.000Z], "2025-07-15 21:00:00"}
      ]

      for {utc_time, expected} <- test_cases do
        assert TimestampManager.format_for_display(utc_time) == expected
      end
    end
  end

  describe "parse_github_time/1" do
    test "parses GitHub API ISO8601 timestamp" do
      github_time = "2025-07-09T10:30:00Z"

      {:ok, parsed_time} = TimestampManager.parse_github_time(github_time)

      assert %DateTime{} = parsed_time
      assert parsed_time.year == 2025
      assert parsed_time.month == 7
      assert parsed_time.day == 9
      assert parsed_time.hour == 10
      assert parsed_time.minute == 30
      assert parsed_time.second == 0
      assert parsed_time.time_zone == "Etc/UTC"
    end

    test "parses GitHub API timestamp with milliseconds" do
      github_time = "2025-07-09T10:30:00.123Z"

      {:ok, parsed_time} = TimestampManager.parse_github_time(github_time)

      assert parsed_time.microsecond == {123_000, 3}
    end

    test "parses legacy timestamp format from thesis-management-tools" do
      legacy_time = "2025-07-18 09:28:25 UTC"

      {:ok, parsed_time} = TimestampManager.parse_github_time(legacy_time)

      assert %DateTime{} = parsed_time
      assert parsed_time.year == 2025
      assert parsed_time.month == 7
      assert parsed_time.day == 18
      assert parsed_time.hour == 9
      assert parsed_time.minute == 28
      assert parsed_time.second == 25
      assert parsed_time.time_zone == "Etc/UTC"
    end

    test "returns error for invalid timestamp format" do
      invalid_times = [
        "invalid-timestamp",
        "2025-07-09",
        "2025-07-09 10:30:00",
        "2025-07-09 10:30:00 JST",
        "",
        nil
      ]

      for invalid_time <- invalid_times do
        assert {:error, _} = TimestampManager.parse_github_time(invalid_time)
      end
    end

    test "returns error for invalid legacy format with invalid date" do
      # Invalid date in legacy format (e.g., February 30th)
      invalid_legacy_time = "2025-02-30 09:28:25 UTC"

      assert {:error, :invalid_format} = TimestampManager.parse_github_time(invalid_legacy_time)
    end

    test "returns error for invalid legacy format with invalid time" do
      # Invalid time in legacy format (e.g., 25:00:00)
      invalid_legacy_time = "2025-07-18 25:00:00 UTC"

      assert {:error, :invalid_format} = TimestampManager.parse_github_time(invalid_legacy_time)
    end
  end

  describe "to_iso8601_utc/1" do
    test "converts DateTime to ISO8601 UTC string" do
      datetime = ~U[2025-07-09 10:30:00.000Z]

      iso_string = TimestampManager.to_iso8601_utc(datetime)

      assert iso_string == "2025-07-09T10:30:00.000Z"
    end

    test "handles microseconds correctly" do
      datetime = ~U[2025-07-09 10:30:00.123456Z]

      iso_string = TimestampManager.to_iso8601_utc(datetime)

      assert iso_string == "2025-07-09T10:30:00.123456Z"
    end
  end

  describe "create_registry_timestamps/1" do
    test "creates all three timestamp fields for new repository" do
      github_created_at = "2025-07-08T06:51:39.835808Z"

      timestamps = TimestampManager.create_registry_timestamps(github_created_at)

      assert Map.has_key?(timestamps, :repository_created_at)
      assert Map.has_key?(timestamps, :registry_created_at)
      assert Map.has_key?(timestamps, :registry_updated_at)

      # repository_created_at は GitHub の時刻
      assert timestamps.repository_created_at == github_created_at

      # registry_created_at と registry_updated_at は現在時刻（同じ値）
      assert timestamps.registry_created_at == timestamps.registry_updated_at

      # 現在時刻との差が1秒以内であることを確認
      {:ok, registry_time, _} = DateTime.from_iso8601(timestamps.registry_created_at)
      now = DateTime.utc_now()
      diff = DateTime.diff(registry_time, now, :second)
      assert abs(diff) <= 1
    end

    test "handles nil github_created_at" do
      timestamps = TimestampManager.create_registry_timestamps(nil)

      # すべて現在時刻
      assert timestamps.repository_created_at == timestamps.registry_created_at
      assert timestamps.registry_created_at == timestamps.registry_updated_at
    end
  end

  describe "update_registry_timestamp/1" do
    test "updates only registry_updated_at field" do
      existing_data = %{
        repository_created_at: "2025-07-08T06:51:39.835808Z",
        registry_created_at: "2025-07-08T15:00:00.000000Z",
        registry_updated_at: "2025-07-08T15:00:00.000000Z"
      }

      updated_data = TimestampManager.update_registry_timestamp(existing_data)

      # repository_created_at と registry_created_at は変更されない
      assert updated_data.repository_created_at == existing_data.repository_created_at
      assert updated_data.registry_created_at == existing_data.registry_created_at

      # registry_updated_at のみ更新される
      assert updated_data.registry_updated_at != existing_data.registry_updated_at

      # 現在時刻との差が1秒以内であることを確認
      {:ok, updated_time, _} = DateTime.from_iso8601(updated_data.registry_updated_at)
      now = DateTime.utc_now()
      diff = DateTime.diff(updated_time, now, :second)
      assert abs(diff) <= 1
    end
  end

  describe "migrate_legacy_timestamps/1" do
    test "migrates legacy created_at and updated_at format" do
      legacy_data = %{
        "created_at" => "2025-07-08T06:51:39.835808Z",
        "updated_at" => "2025-07-08T16:20:06.000000Z"
      }

      migrated_data = TimestampManager.migrate_legacy_timestamps(legacy_data)

      assert migrated_data["repository_created_at"] == legacy_data["created_at"]
      assert migrated_data["registry_created_at"] == legacy_data["created_at"]
      assert migrated_data["registry_updated_at"] == legacy_data["updated_at"]

      # 元のフィールドは削除される
      refute Map.has_key?(migrated_data, "created_at")
      refute Map.has_key?(migrated_data, "updated_at")
    end

    test "migrates legacy created_at only format" do
      legacy_data = %{
        "created_at" => "2025-07-08T06:51:39.835808Z"
      }

      migrated_data = TimestampManager.migrate_legacy_timestamps(legacy_data)

      assert migrated_data["repository_created_at"] == legacy_data["created_at"]
      assert migrated_data["registry_created_at"] == legacy_data["created_at"]

      # registry_updated_at は現在時刻
      {:ok, updated_time, _} = DateTime.from_iso8601(migrated_data["registry_updated_at"])
      now = DateTime.utc_now()
      diff = DateTime.diff(updated_time, now, :second)
      assert abs(diff) <= 1

      refute Map.has_key?(migrated_data, "created_at")
    end

    test "preserves other fields during migration" do
      legacy_data = %{
        "created_at" => "2025-07-08T06:51:39.835808Z",
        "student_id" => "k21rs001",
        "repository_type" => "sotsuron",
        "github_username" => "student1"
      }

      migrated_data = TimestampManager.migrate_legacy_timestamps(legacy_data)

      # その他のフィールドは保持される
      assert migrated_data["student_id"] == "k21rs001"
      assert migrated_data["repository_type"] == "sotsuron"
      assert migrated_data["github_username"] == "student1"
    end

    test "returns unchanged data if already migrated" do
      modern_data = %{
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "2025-07-08T15:00:00.000000Z",
        "registry_updated_at" => "2025-07-08T15:30:00.000000Z"
      }

      result = TimestampManager.migrate_legacy_timestamps(modern_data)

      assert result == modern_data
    end
  end

  describe "needs_migration?/1" do
    test "returns true for legacy format with created_at" do
      legacy_data = %{"created_at" => "2025-07-08T06:51:39.835808Z"}

      assert TimestampManager.needs_migration?(legacy_data)
    end

    test "returns false for modern format" do
      modern_data = %{
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "2025-07-08T15:00:00.000000Z",
        "registry_updated_at" => "2025-07-08T15:30:00.000000Z"
      }

      refute TimestampManager.needs_migration?(modern_data)
    end

    test "returns false for data without timestamp fields" do
      data_without_timestamps = %{
        "student_id" => "k21rs001",
        "repository_type" => "sotsuron"
      }

      refute TimestampManager.needs_migration?(data_without_timestamps)
    end
  end

  describe "validate_timestamps/1" do
    test "validates data with all required timestamp fields" do
      valid_data = %{
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "2025-07-08T15:00:00.000000Z",
        "registry_updated_at" => "2025-07-08T16:20:06.000000Z"
      }

      assert {:ok, ^valid_data} = TimestampManager.validate_timestamps(valid_data)
    end

    test "returns error for missing timestamp fields" do
      data_missing_fields = %{
        "repository_created_at" => "2025-07-08T06:51:39.835808Z"
      }

      {:error, message} = TimestampManager.validate_timestamps(data_missing_fields)
      assert String.contains?(message, "Missing timestamp fields")
      assert String.contains?(message, "registry_created_at")
      assert String.contains?(message, "registry_updated_at")
    end

    test "returns error for nil timestamp values" do
      data_with_nil = %{
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => nil,
        "registry_updated_at" => "2025-07-08T16:20:06.000000Z"
      }

      {:error, message} = TimestampManager.validate_timestamps(data_with_nil)
      assert String.contains?(message, "Missing timestamp fields")
      assert String.contains?(message, "registry_created_at")
    end

    test "returns error for invalid timestamp format" do
      data_invalid_format = %{
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "invalid-timestamp",
        "registry_updated_at" => "2025-07-08 16:20:06"
      }

      {:error, message} = TimestampManager.validate_timestamps(data_invalid_format)
      assert String.contains?(message, "Invalid timestamp format")
      assert String.contains?(message, "registry_created_at")
      assert String.contains?(message, "registry_updated_at")
    end

    test "accepts other fields in addition to timestamps" do
      data_with_extra = %{
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "2025-07-08T15:00:00.000000Z",
        "registry_updated_at" => "2025-07-08T16:20:06.000000Z",
        "student_id" => "k21rs001",
        "repository_type" => "sotsuron"
      }

      assert {:ok, ^data_with_extra} = TimestampManager.validate_timestamps(data_with_extra)
    end
  end

  describe "extract_display_timestamps/1" do
    test "extracts and formats all timestamps for display" do
      data = %{
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "2025-07-08T15:00:00.000000Z",
        "registry_updated_at" => "2025-07-08T16:20:06.000000Z"
      }

      display_timestamps = TimestampManager.extract_display_timestamps(data)

      assert display_timestamps.repository_created == "2025-07-08 15:51:39"
      assert display_timestamps.registry_created == "2025-07-09 00:00:00"
      assert display_timestamps.registry_updated == "2025-07-09 01:20:06"
    end

    test "handles missing timestamps gracefully" do
      data = %{
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => nil
        # registry_updated_at is missing
      }

      display_timestamps = TimestampManager.extract_display_timestamps(data)

      assert display_timestamps.repository_created == "2025-07-08 15:51:39"
      assert display_timestamps.registry_created == "N/A"
      assert display_timestamps.registry_updated == "N/A"
    end

    test "handles invalid timestamp formats" do
      data = %{
        "repository_created_at" => "invalid-timestamp",
        "registry_created_at" => "2025-07-08T15:00:00.000000Z",
        "registry_updated_at" => "2025-07-08 16:20:06"
      }

      display_timestamps = TimestampManager.extract_display_timestamps(data)

      assert display_timestamps.repository_created == "Invalid"
      assert display_timestamps.registry_created == "2025-07-09 00:00:00"
      assert display_timestamps.registry_updated == "Invalid"
    end

    test "preserves other data fields" do
      data = %{
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "2025-07-08T15:00:00.000000Z",
        "registry_updated_at" => "2025-07-08T16:20:06.000000Z",
        "student_id" => "k21rs001"
      }

      display_timestamps = TimestampManager.extract_display_timestamps(data)

      # extract_display_timestamps は表示用のタイムスタンプのみを返す
      assert Enum.sort(Map.keys(display_timestamps)) ==
               Enum.sort([:repository_created, :registry_created, :registry_updated])

      refute Map.has_key?(display_timestamps, :student_id)
    end
  end

  describe "compare_timestamps/2" do
    test "compares timestamps correctly" do
      earlier = "2025-07-08T10:00:00.000000Z"
      later = "2025-07-08T15:00:00.000000Z"
      same = "2025-07-08T10:00:00.000000Z"

      assert TimestampManager.compare_timestamps(earlier, later) == :lt
      assert TimestampManager.compare_timestamps(later, earlier) == :gt
      assert TimestampManager.compare_timestamps(earlier, same) == :eq
    end

    test "handles microseconds in comparison" do
      time1 = "2025-07-08T10:00:00.000000Z"
      time2 = "2025-07-08T10:00:00.000001Z"

      assert TimestampManager.compare_timestamps(time1, time2) == :lt
      assert TimestampManager.compare_timestamps(time2, time1) == :gt
    end

    test "returns :error for invalid timestamps" do
      valid_time = "2025-07-08T10:00:00.000000Z"
      invalid_time = "invalid-timestamp"

      assert TimestampManager.compare_timestamps(valid_time, invalid_time) == :error
      assert TimestampManager.compare_timestamps(invalid_time, valid_time) == :error
      assert TimestampManager.compare_timestamps(invalid_time, invalid_time) == :error
    end

    test "returns :error for nil timestamps" do
      valid_time = "2025-07-08T10:00:00.000000Z"

      assert TimestampManager.compare_timestamps(valid_time, nil) == :error
      assert TimestampManager.compare_timestamps(nil, valid_time) == :error
      assert TimestampManager.compare_timestamps(nil, nil) == :error
    end

    test "compares timestamps across date boundaries" do
      end_of_year = "2025-12-31T23:59:59.999999Z"
      start_of_next_year = "2026-01-01T00:00:00.000000Z"

      assert TimestampManager.compare_timestamps(end_of_year, start_of_next_year) == :lt
    end
  end
end
