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
