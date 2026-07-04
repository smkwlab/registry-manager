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
  Creates timestamp fields for a new registry entry.

  Returns a map with all three timestamp fields:
  - repository_created_at: From GitHub API (or current time if nil)
  - registry_created_at: Current time (when added to registry)
  - registry_updated_at: Current time (same as registry_created_at for new entries)
  """
  @spec create_registry_timestamps(String.t() | nil) :: %{
          repository_created_at: String.t(),
          registry_created_at: String.t(),
          registry_updated_at: String.t()
        }
  def create_registry_timestamps(github_created_at) do
    now = current_utc_time()
    now_iso = to_iso8601_utc(now)

    repository_created_at =
      case github_created_at do
        nil -> now_iso
        github_time -> github_time
      end

    %{
      repository_created_at: repository_created_at,
      registry_created_at: now_iso,
      registry_updated_at: now_iso
    }
  end

  @doc """
  Updates only the registry_updated_at timestamp for existing entries.

  Preserves repository_created_at and registry_created_at.
  """
  @spec update_registry_timestamp(map()) :: %{
          :registry_updated_at => String.t(),
          optional(any()) => any()
        }
  def update_registry_timestamp(existing_data) do
    now = current_utc_time()
    now_iso = to_iso8601_utc(now)

    existing_data
    |> Map.put(:registry_updated_at, now_iso)
  end

  @doc """
  Migrates legacy timestamp format to new 3-field format.

  Legacy format:
  - "created_at" -> "repository_created_at" and "registry_created_at"
  - "updated_at" -> "registry_updated_at" (or existing registry_updated_at, or current time)

  Removes the legacy fields after migration.
  """
  @spec migrate_legacy_timestamps(map()) :: map()
  def migrate_legacy_timestamps(data) do
    if needs_migration?(data) do
      now = current_utc_time()
      now_iso = to_iso8601_utc(now)

      created_at = Map.get(data, "created_at")
      # Use existing registry_updated_at if present, otherwise updated_at, otherwise current time
      updated_at =
        Map.get(data, "registry_updated_at") ||
          Map.get(data, "updated_at") ||
          now_iso

      data
      |> Map.put("repository_created_at", created_at)
      |> Map.put("registry_created_at", created_at)
      |> Map.put("registry_updated_at", updated_at)
      |> Map.delete("created_at")
      |> Map.delete("updated_at")
    else
      data
    end
  end

  @doc """
  Checks if data needs migration from legacy timestamp format.

  Returns true if data has "created_at" but not "repository_created_at".
  """
  @spec needs_migration?(map()) :: boolean()
  def needs_migration?(data) do
    Map.has_key?(data, "created_at") and not Map.has_key?(data, "repository_created_at")
  end

  @doc """
  Validates timestamp format and ensures all required fields are present.
  """
  @spec validate_timestamps(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_timestamps(data) do
    required_fields = ["repository_created_at", "registry_created_at", "registry_updated_at"]

    missing_fields =
      Enum.filter(required_fields, fn field ->
        not Map.has_key?(data, field) or is_nil(Map.get(data, field))
      end)

    if Enum.empty?(missing_fields) do
      # Validate timestamp format
      case validate_timestamp_format(data) do
        :ok -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "Missing timestamp fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  defp validate_timestamp_format(data) do
    timestamp_fields = ["repository_created_at", "registry_created_at", "registry_updated_at"]

    invalid_fields =
      Enum.filter(timestamp_fields, fn field ->
        case parse_github_time(Map.get(data, field)) do
          {:ok, _} -> false
          {:error, _} -> true
        end
      end)

    if Enum.empty?(invalid_fields) do
      :ok
    else
      {:error, "Invalid timestamp format in fields: #{Enum.join(invalid_fields, ", ")}"}
    end
  end

  @doc """
  Extracts timestamp information for display purposes.

  Returns a map with formatted timestamps for human-readable display.
  """
  @spec extract_display_timestamps(map()) :: %{
          repository_created: String.t(),
          registry_created: String.t(),
          registry_updated: String.t()
        }
  def extract_display_timestamps(data) do
    %{
      repository_created: format_timestamp_for_display(data, "repository_created_at"),
      registry_created: format_timestamp_for_display(data, "registry_created_at"),
      registry_updated: format_timestamp_for_display(data, "registry_updated_at")
    }
  end

  defp format_timestamp_for_display(data, field) do
    case Map.get(data, field) do
      nil ->
        "N/A"

      timestamp_string ->
        case parse_github_time(timestamp_string) do
          {:ok, datetime} -> format_for_display(datetime)
          {:error, _} -> "Invalid"
        end
    end
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
