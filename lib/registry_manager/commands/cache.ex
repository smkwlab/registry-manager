defmodule RegistryManager.Commands.Cache do
  @moduledoc """
  Cache management command implementation for registry-manager v4.

  Provides cache control functionality for GitHub API responses stored locally.
  Supports three main operations:
  - status: View cache status and statistics
  - clear: Remove cache entries
  - refresh: Force refresh by clearing cache entries

  All commands support both global operations (all repositories) and 
  specific repository operations.

  Aliases:
  - cache-status (hyphenated version of cache status)
  - cache-clear (hyphenated version of cache clear)
  - cache-refresh (hyphenated version of cache refresh)
  """

  alias RegistryManager.{Cache, TimestampManager}
  alias RegistryManager.Cache.CacheStatus
  alias RegistryManager.Repository.DataStore

  @doc """
  Runs the cache command with given arguments and options.

  ## Commands
  - `["status"]` or `["status", repo_name]` - Show cache status
  - `["clear"]` or `["clear", repo_name]` - Clear cache
  - `["refresh"]` or `["refresh", repo_name]` - Refresh cache
  - `["cache-status"]` etc. - Hyphenated aliases

  ## Options
  - `verbose` (boolean): Show verbose output
  - `force` (boolean): Skip confirmation for destructive operations
  - `cache_dir` (string): Override default cache directory (for testing)

  ## Test Parameters (for testing only)
  - `cache_dir` (string): Override cache directory
  """
  @spec run(list(String.t()), keyword(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, opts, test_params \\ []) do
    cache_dir = get_cache_dir(opts, test_params)
    verbose = Keyword.get(opts, :verbose, false)

    case parse_command(args) do
      {:status, repo_name} ->
        handle_status(repo_name, cache_dir, verbose, test_params)

      {:clear, repo_name} ->
        handle_clear(repo_name, cache_dir, opts, verbose)

      {:refresh, repo_name} ->
        handle_refresh(repo_name, cache_dir, verbose)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses cache command arguments.
  """
  @spec parse_command(list(String.t())) ::
          {:status | :clear | :refresh, String.t() | nil} | {:error, String.t()}
  def parse_command(args) do
    case args do
      [command | rest] when command in ["status", "cache-status"] ->
        parse_cache_args(:status, rest, "cache status")

      [command | rest] when command in ["clear", "cache-clear"] ->
        parse_cache_args(:clear, rest, "cache clear")

      [command | rest] when command in ["refresh", "cache-refresh"] ->
        parse_cache_args(:refresh, rest, "cache refresh")

      [unknown_command] ->
        {:error, "Invalid cache command: #{unknown_command}"}

      [] ->
        {:error, "No cache command specified"}

      _ ->
        {:error, "Invalid cache command arguments"}
    end
  end

  defp parse_cache_args(command, args, command_name) do
    case args do
      [] -> {command, nil}
      [repo_name] -> {command, repo_name}
      _ -> {:error, "Too many arguments for #{command_name}"}
    end
  end

  defp get_cache_dir(opts, test_params) do
    Keyword.get(test_params, :cache_dir) ||
      Keyword.get(opts, :cache_dir) ||
      Cache.get_cache_dir()
  end

  defp handle_status(repo_name, cache_dir, verbose, test_params) do
    if verbose do
      IO.puts("Cache directory: #{cache_dir}")
    end

    case repo_name do
      nil -> show_all_cache_status(cache_dir, verbose, test_params)
      name -> show_single_cache_status(name, cache_dir, verbose)
    end
  end

  defp show_all_cache_status(cache_dir, verbose, test_params) do
    stats = Cache.get_cache_stats(cache_dir: cache_dir)
    output = build_cache_overview(stats, cache_dir, verbose, test_params)
    {:ok, output}
  end

  defp get_all_repository_statuses(cache_dir, test_params) do
    case Keyword.get(test_params, :registry_data) do
      nil ->
        # 本番環境: レジストリから取得
        get_repositories_from_registry(cache_dir)

      registry_data ->
        # テスト環境: モックデータを使用
        get_repositories_from_test_data(registry_data, cache_dir)
    end
  end

  defp get_repositories_from_registry(cache_dir) do
    case DataStore.get_all_entries() do
      {:ok, registry_data} ->
        get_repositories_from_test_data(registry_data, cache_dir)

      {:error, _reason} ->
        # レジストリデータが取得できない場合は従来の方法にフォールバック
        get_repositories_from_cache_files(cache_dir)
    end
  end

  defp get_repositories_from_test_data(registry_data, cache_dir) do
    registry_data
    |> Map.keys()
    |> Enum.map(fn repo_name ->
      {:ok, status} = Cache.status(repo_name, cache_dir: cache_dir)
      status
    end)
    |> Enum.sort_by(& &1.repository)
  end

  defp get_repositories_from_cache_files(cache_dir) do
    activity_dir = Path.join(cache_dir, "activity")

    if File.exists?(activity_dir) do
      File.ls!(activity_dir)
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(fn file ->
        repo_name = String.replace_suffix(file, ".json", "")
        {:ok, status} = Cache.status(repo_name, cache_dir: cache_dir)
        status
      end)
      |> Enum.sort_by(& &1.repository)
    else
      []
    end
  end

  defp build_cache_overview(stats, cache_dir, verbose, test_params) do
    repo_statuses = get_all_repository_statuses(cache_dir, test_params)

    header = "Cache Status\n============\n"

    repo_lines =
      if Enum.empty?(repo_statuses) do
        ["No cache entries found."]
      else
        [
          "Repository                 Status    Cached At           Expires At          Size",
          "-------------------------  --------  ------------------  ------------------  --------"
        ] ++
          Enum.map(repo_statuses, fn status ->
            format_cache_status_line(status)
          end)
      end

    stats_lines = [
      "",
      "Summary:",
      "  Total entries: #{stats.total_entries}",
      "  Valid entries: #{stats.valid_entries}",
      "  Expired entries: #{stats.expired_entries}",
      "  Total size: #{format_bytes(stats.total_size_bytes)}"
    ]

    verbose_lines =
      if verbose do
        [
          "",
          "Cache directory: #{cache_dir}"
        ]
      else
        []
      end

    ([header] ++ repo_lines ++ stats_lines ++ verbose_lines)
    |> Enum.join("\n")
  end

  defp format_cache_status_line(status) do
    repo_name = String.pad_trailing(status.repository, 25)

    status_text =
      cond do
        status.exists and not status.expired -> "Valid"
        status.expired -> "Expired"
        true -> "Not cached"
      end

    status_text = String.pad_trailing(status_text, 8)

    cached_at = format_timestamp_or_na(status.cached_at)
    cached_at = String.pad_trailing(cached_at, 18)

    expires_at = format_timestamp_or_na(status.expires_at)
    expires_at = String.pad_trailing(expires_at, 18)

    size = format_bytes(status.size_bytes)

    "#{repo_name}  #{status_text}  #{cached_at}  #{expires_at}  #{size}"
  end

  defp format_timestamp_or_na(nil), do: "N/A"

  defp format_timestamp_or_na(timestamp_string) do
    case TimestampManager.parse_github_time(timestamp_string) do
      {:ok, datetime} ->
        datetime
        |> TimestampManager.format_for_display()
        # YYYY-MM-DD HH:MM
        |> String.slice(0, 16)

      {:error, _} ->
        "Invalid"
    end
  end

  defp format_bytes(bytes) do
    cond do
      bytes >= 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} bytes"
    end
  end

  defp show_single_cache_status(repo_name, cache_dir, verbose) do
    {:ok, status} = Cache.status(repo_name, cache_dir: cache_dir)
    output = format_cache_status(status, verbose)
    {:ok, output}
  end

  @doc """
  Formats cache status for a single repository.
  """
  @spec format_cache_status(CacheStatus.t(), boolean()) :: String.t()
  def format_cache_status(status, verbose) do
    header =
      "Cache Status: #{status.repository}\n" <>
        String.duplicate("=", 30 + String.length(status.repository)) <> "\n"

    status_text =
      cond do
        status.exists and not status.expired -> "Valid"
        status.expired -> "Expired"
        true -> "Not cached"
      end

    main_info = [
      "Status: #{status_text}",
      "Size: #{format_bytes(status.size_bytes)}"
    ]

    time_info =
      if status.exists do
        [
          "Cached at: #{format_timestamp_or_na(status.cached_at)}",
          "Expires at: #{format_timestamp_or_na(status.expires_at)}"
        ]
      else
        []
      end

    verbose_info =
      if verbose and status.exists do
        cache_file =
          Cache.get_activity_cache_path(status.repository, cache_dir: Cache.get_cache_dir())

        [
          "",
          "Cache file: #{cache_file}"
        ]
      else
        []
      end

    ([header] ++ main_info ++ time_info ++ verbose_info)
    |> Enum.join("\n")
  end

  defp handle_clear(repo_name, cache_dir, opts, verbose) do
    force = Keyword.get(opts, :force, false)

    case repo_name do
      nil ->
        if force or confirm_clear_all() do
          handle_clear_all_cache(cache_dir, verbose)
        else
          {:ok, "Cache clear cancelled."}
        end

      name ->
        if verbose do
          IO.puts("Clearing cache for #{name}")
        end

        clear_single_cache(name, cache_dir, verbose)
    end
  end

  defp confirm_clear_all do
    # テスト環境では確認をスキップ
    if test_env?() do
      true
    else
      prompt_user_confirmation()
    end
  end

  defp test_env? do
    # escriptでは Mix.env() が使えないため、環境変数またはアプリケーション設定を使用
    # ExUnitが実行中の場合もテスト環境と判定
    Application.get_env(:registry_manager, :test_mode, false) or
      System.get_env("MIX_ENV") == "test" or
      (Code.ensure_loaded?(ExUnit) and Process.whereis(ExUnit.Server) != nil)
  end

  defp prompt_user_confirmation do
    IO.write("Are you sure you want to clear all cache? (y/N): ")

    case IO.gets("") do
      # EOF の場合は false を返す
      :eof -> false
      input when is_binary(input) -> parse_user_input(input)
      _ -> false
    end
  end

  defp parse_user_input(input) do
    case String.trim(input) |> String.downcase() do
      "y" -> true
      "yes" -> true
      _ -> false
    end
  end

  defp handle_clear_all_cache(cache_dir, verbose) do
    if verbose do
      IO.puts("Clearing cache directory: #{cache_dir}")
    end

    clear_all_cache(cache_dir, verbose)
  end

  defp clear_all_cache(cache_dir, verbose) do
    :ok = Cache.clear(cache_dir: cache_dir)

    message =
      if verbose do
        "Clearing cache\nAll cache entries cleared from #{cache_dir}"
      else
        "Cache cleared successfully."
      end

    {:ok, message}
  end

  defp clear_single_cache(repo_name, cache_dir, verbose) do
    :ok = Cache.delete(repo_name, cache_dir: cache_dir)

    message =
      if verbose do
        "Cache entry for #{repo_name} cleared from #{cache_dir}"
      else
        "Cache cleared for #{repo_name}."
      end

    {:ok, message}
  end

  defp handle_refresh(repo_name, cache_dir, verbose) do
    if verbose do
      if repo_name do
        IO.puts("Refreshing cache for #{repo_name}")
      else
        IO.puts("Refreshing all cache entries")
      end
    end

    case repo_name do
      nil -> refresh_all_cache(cache_dir, verbose)
      name -> refresh_single_cache(name, cache_dir, verbose)
    end
  end

  defp refresh_all_cache(cache_dir, verbose) do
    :ok = Cache.clear(cache_dir: cache_dir)

    message =
      if verbose do
        "All cache entries refreshed (cleared for re-fetch)"
      else
        "Cache refreshed successfully."
      end

    {:ok, message}
  end

  defp refresh_single_cache(repo_name, cache_dir, verbose) do
    :ok = Cache.refresh(repo_name, cache_dir: cache_dir)

    message =
      if verbose do
        "Cache entry for #{repo_name} refreshed (cleared for re-fetch)"
      else
        "Cache refreshed for #{repo_name}."
      end

    {:ok, message}
  end
end
