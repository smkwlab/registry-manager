defmodule RegistryManager.Migration do
  @moduledoc """
  Data migration tools for converting v1 format to v4 format

  Handles the migration of registry data from the legacy format (with status, stage)
  to the new simplified format compatible with v4 architecture.
  """

  alias RegistryManager.GitHubAPI

  @doc """
  Migrate registry data from v1 format to v4 format

  ## Migration Rules:
  - Keep: student_id, repository_type, github_username
  - Convert: updated_at -> registry_updated_at, repository_created_at (if exists)
  - Remove: status, stage (deprecated fields)
  - Add: created_at (from repository_created_at or current timestamp)

  ## Returns:
  - {:ok, {migrated_data, migration_stats}} on success
  - {:error, reason} on failure
  """
  def migrate_to_v4(registry_data) when is_map(registry_data) do
    migration_stats = %{
      total_entries: map_size(registry_data),
      migrated: 0,
      already_v4: 0,
      errors: []
    }

    {migrated_data, final_stats} =
      Enum.reduce(registry_data, {%{}, migration_stats}, &migrate_registry_entry/2)

    {:ok, {migrated_data, final_stats}}
  end

  defp migrate_registry_entry({repo_name, repo_info}, {acc_data, acc_stats}) do
    case migrate_single_entry(repo_name, repo_info) do
      {:ok, migrated_entry} ->
        handle_successful_migration(repo_name, repo_info, migrated_entry, acc_data, acc_stats)

      {:error, reason} ->
        handle_migration_error(repo_name, repo_info, reason, acc_data, acc_stats)
    end
  end

  defp handle_successful_migration(repo_name, repo_info, migrated_entry, acc_data, acc_stats) do
    updated_data = Map.put(acc_data, repo_name, migrated_entry)

    if is_v4_format?(repo_info) do
      updated_stats = %{acc_stats | already_v4: acc_stats.already_v4 + 1}
      {updated_data, updated_stats}
    else
      updated_stats = %{acc_stats | migrated: acc_stats.migrated + 1}
      {updated_data, updated_stats}
    end
  end

  defp handle_migration_error(repo_name, repo_info, reason, acc_data, acc_stats) do
    error_info = %{repo_name: repo_name, reason: reason}
    updated_stats = %{acc_stats | errors: [error_info | acc_stats.errors]}
    # Keep original entry on error
    updated_data = Map.put(acc_data, repo_name, repo_info)
    {updated_data, updated_stats}
  end

  @doc """
  Check if a registry entry is already in v4 format
  """
  def is_v4_format?(repo_info) when is_map(repo_info) do
    has_created_at = Map.has_key?(repo_info, "created_at")
    has_registry_updated = Map.has_key?(repo_info, "registry_updated_at")
    has_legacy_fields = Map.has_key?(repo_info, "status") or Map.has_key?(repo_info, "stage")

    (has_created_at or has_registry_updated) and not has_legacy_fields
  end

  @doc """
  Migrate a single registry entry from v1 to v4 format
  """
  def migrate_single_entry(repo_name, repo_info) when is_map(repo_info) do
    if is_v4_format?(repo_info) do
      # Already in v4 format, return as-is
      {:ok, repo_info}
    else
      # Migrate from v1 to v4
      migrate_v1_entry(repo_name, repo_info)
    end
  end

  defp migrate_v1_entry(repo_name, repo_info) do
    # Required fields (must exist)
    student_id = Map.get(repo_info, "student_id")
    repository_type = Map.get(repo_info, "repository_type")

    if is_nil(student_id) or is_nil(repository_type) do
      {:error, "Missing required fields: student_id or repository_type"}
    else
      # Build v4 format entry
      base_entry = %{
        "student_id" => student_id,
        "repository_type" => normalize_repository_type(repository_type, repo_name)
      }

      # Handle timestamps
      timestamp_entry = add_timestamps(base_entry, repo_info)

      # Add optional fields
      final_entry = add_optional_fields(timestamp_entry, repo_info)

      {:ok, final_entry}
    end
  rescue
    error ->
      {:error, "Migration failed: #{inspect(error)}"}
  end

  # legacy の thesis は repo 名から実タイプを導出する（issue #11 / TMT#471:
  # 実データでは thesis の大半が latex-template 派生の研究会 repo だった）。
  # -sotsuron / -master 分岐は現本番データには存在しない組み合わせだが、
  # v1 時代のテストデータ（例: k19rs999-sotsuron + thesis）と過去バックアップの
  # 移行に対する防御として残している
  defp normalize_repository_type("thesis", repo_name) do
    cond do
      String.ends_with?(repo_name, "-sotsuron") -> "sotsuron"
      String.ends_with?(repo_name, "-master") -> "master"
      String.ends_with?(repo_name, "-thesis") -> "master"
      true -> "latex"
    end
  end

  defp normalize_repository_type("ise", _repo_name), do: "ise-report"
  defp normalize_repository_type(type, _repo_name), do: type

  defp add_timestamps(entry, repo_info) do
    current_timestamp = generate_current_timestamp()

    # Handle created_at
    created_at =
      case Map.get(repo_info, "repository_created_at") do
        nil -> current_timestamp
        timestamp -> normalize_timestamp(timestamp) || current_timestamp
      end

    # Handle registry_updated_at
    registry_updated_at =
      case Map.get(repo_info, "updated_at") do
        nil -> current_timestamp
        timestamp -> normalize_timestamp(timestamp) || current_timestamp
      end

    entry
    |> Map.put("created_at", created_at)
    |> Map.put("registry_updated_at", registry_updated_at)
  end

  defp generate_current_timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp add_optional_fields(entry, repo_info) do
    # Add github_username if present
    case Map.get(repo_info, "github_username") do
      nil ->
        entry

      username when is_binary(username) and username != "" ->
        Map.put(entry, "github_username", username)

      _ ->
        entry
    end
  end

  defp normalize_timestamp(timestamp) when is_binary(timestamp) do
    cond do
      # Format: "2025-07-07 16:44:44 UTC"
      utc_format?(timestamp) ->
        normalize_utc_timestamp(timestamp)

      # Format: "2025-07-08T06:51:39.835808Z" (already ISO8601)
      iso8601_format?(timestamp) ->
        normalize_iso8601_timestamp(timestamp)

      # Other ISO8601 formats
      true ->
        normalize_iso8601_timestamp(timestamp)
    end
  end

  defp normalize_timestamp(_), do: nil

  defp utc_format?(timestamp) do
    Regex.match?(~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC$/, timestamp)
  end

  defp iso8601_format?(timestamp) do
    Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/, timestamp)
  end

  defp normalize_utc_timestamp(timestamp) do
    iso_string = String.replace(timestamp, " UTC", "Z")
    parse_datetime_to_iso8601(iso_string)
  end

  defp normalize_iso8601_timestamp(timestamp) do
    parse_datetime_to_iso8601(timestamp)
  end

  defp parse_datetime_to_iso8601(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _ -> nil
    end
  end

  @doc """
  Perform dry run migration to preview changes
  """
  def dry_run_migration(registry_data) when is_map(registry_data) do
    {:ok, {_migrated_data, stats}} = migrate_to_v4(registry_data)
    report = generate_migration_report(stats)
    {:ok, report}
  end

  @doc """
  Generate migration report
  """
  def generate_migration_report(stats) do
    """
    Migration Analysis Report
    ========================

    Total entries:        #{stats.total_entries}
    Already v4 format:    #{stats.already_v4}
    Require migration:    #{stats.migrated}
    Migration errors:     #{length(stats.errors)}

    #{if length(stats.errors) > 0 do
      "Errors:\n" <> (stats.errors |> Enum.map(fn err -> "  - #{err.repo_name}: #{err.reason}" end) |> Enum.join("\n"))
    else
      "No migration errors detected."
    end}

    Summary:
    #{if stats.migrated > 0 do
      "#{stats.migrated} entries will be migrated to v4 format."
    else
      "All entries are already in v4 format."
    end}
    """
  end

  @doc """
  Perform migration and update registry via GitHub API
  """
  def execute_migration(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    verbose = Keyword.get(opts, :verbose, false)

    if verbose, do: IO.puts("Fetching current registry data...")

    case GitHubAPI.get_repositories_json() do
      {:ok, {registry_data, current_sha}} ->
        handle_migration_execution(registry_data, current_sha, dry_run, verbose)

      {:error, reason} ->
        {:error, "Failed to fetch registry data: #{reason}"}
    end
  end

  defp handle_migration_execution(registry_data, current_sha, dry_run, verbose) do
    if verbose, do: IO.puts("Analyzing migration requirements...")

    {:ok, {migrated_data, stats}} = migrate_to_v4(registry_data)

    if verbose do
      report = generate_migration_report(stats)
      IO.puts(report)
    end

    if dry_run do
      {:ok, "Dry run completed. Use --no-dry-run to execute migration."}
    else
      execute_migration_if_needed(migrated_data, current_sha, stats, verbose)
    end
  end

  defp execute_migration_if_needed(migrated_data, current_sha, stats, verbose) do
    if stats.migrated > 0 do
      execute_migration_update(migrated_data, current_sha, stats, verbose)
    else
      {:ok, "No migration needed. All entries are already in v4 format."}
    end
  end

  defp execute_migration_update(migrated_data, current_sha, stats, verbose) do
    if verbose, do: IO.puts("Updating registry with migrated data...")

    commit_message =
      "Migrate registry data to v4 format\n\n" <>
        "- Migrated #{stats.migrated} entries to v4 format\n" <>
        "- Kept #{stats.already_v4} entries already in v4 format\n" <>
        "- Total entries: #{stats.total_entries}"

    case GitHubAPI.update_repositories_json(migrated_data, current_sha, commit_message) do
      {:ok, _new_sha} ->
        {:ok, "✅ Migration completed successfully. #{stats.migrated} entries migrated."}

      {:error, reason} ->
        {:error, "Failed to update registry: #{reason}"}
    end
  end
end
