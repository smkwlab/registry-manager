defmodule RegistryManager.TimestampManager do
  @moduledoc """
  Timestamp management for registry-manager.

  Handles the three timestamp fields required for registry entries:
  - repository_created_at: When the GitHub repository was created
  - registry_created_at: When the entry was first added to the registry
  - registry_updated_at: When the entry was last updated in the registry

  Also provides JST formatting for display and migration from legacy formats.
  """

  @doc """
  Returns the current UTC time.
  """
  @spec current_utc_time() :: DateTime.t()
  def current_utc_time do
    DateTime.utc_now()
  end

  @doc """
  Formats a UTC DateTime for display in JST without timezone suffix.

  Example: 2025-07-09 19:30:00 (JST displayed as local time)
  """
  @spec format_for_display(DateTime.t()) :: String.t()
  def format_for_display(datetime) do
    # JST は UTC+9 なので、9時間追加する
    jst_datetime = DateTime.add(datetime, 9 * 60 * 60, :second)

    jst_datetime
    |> DateTime.to_string()
    # ミリ秒とZを削除
    |> String.replace(~r/\.\d+Z?$/, "")
  end

  @doc """
  Parses GitHub API timestamp string to DateTime.

  Supports multiple formats:
  - ISO8601: "2025-07-09T10:30:00Z" (GitHub API format)
  - Legacy: "2025-07-18 09:28:25 UTC" (old format from thesis-management-tools)
  """
  @spec parse_github_time(String.t() | nil) :: {:ok, DateTime.t()} | {:error, term()}
  def parse_github_time(nil), do: {:error, :nil_timestamp}
  def parse_github_time(""), do: {:error, :empty_timestamp}

  def parse_github_time(github_time_string) when is_binary(github_time_string) do
    # Try ISO8601 format first
    case DateTime.from_iso8601(github_time_string) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _} ->
        # Try legacy format: "2025-07-18 09:28:25 UTC"
        parse_legacy_format(github_time_string)
    end
  end

  defp parse_legacy_format(timestamp_string) do
    # Parse format: "2025-07-18 09:28:25 UTC"
    case Regex.run(~r/^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) UTC$/, timestamp_string) do
      [_, year, month, day, hour, minute, second] ->
        with {:ok, date} <-
               Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)),
             {:ok, time} <-
               Time.new(
                 String.to_integer(hour),
                 String.to_integer(minute),
                 String.to_integer(second)
               ),
             {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
          {:ok, datetime}
        else
          _ -> {:error, :invalid_format}
        end

      nil ->
        {:error, :invalid_format}
    end
  end

  @doc """
  Converts DateTime to ISO8601 UTC string.
  """
  @spec to_iso8601_utc(DateTime.t()) :: String.t()
  def to_iso8601_utc(datetime) do
    DateTime.to_iso8601(datetime)
  end

  @doc """
  Compares timestamps to determine the order of events.

  Returns :lt, :eq, or :gt based on chronological order.
  """
  @spec compare_timestamps(String.t(), String.t()) :: :lt | :eq | :gt | :error
  def compare_timestamps(timestamp1, timestamp2) do
    with {:ok, dt1} <- parse_github_time(timestamp1),
         {:ok, dt2} <- parse_github_time(timestamp2) do
      DateTime.compare(dt1, dt2)
    else
      _ -> :error
    end
  end
end
