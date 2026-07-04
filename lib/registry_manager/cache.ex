defmodule RegistryManager.Cache do
  @moduledoc """
  Cache management for registry-manager.

  Provides caching functionality for GitHub API responses, particularly
  activity information that is expensive to fetch repeatedly.

  Cache structure:
  ~/.cache/registry-manager/
  ├── activity/           # list --activity 用キャッシュ
  │   └── {repo_name}.json
  ├── pr-status/          # pr-status 用キャッシュ (Issue #120)
  │   └── {repo_name}.json
  ├── metadata.json
  └── .gitignore
  """

  @default_cache_dir Path.join([System.user_home!(), ".cache", "registry-manager"])
  @default_ttl_hours 1
  @default_category "activity"

  defmodule CacheStatus do
    @moduledoc """
    Represents the status of a cache entry.
    """
    defstruct [
      :repository,
      :exists,
      :expired,
      :cached_at,
      :expires_at,
      :size_bytes
    ]

    @type t :: %__MODULE__{
            repository: String.t(),
            exists: boolean(),
            expired: boolean(),
            cached_at: String.t() | nil,
            expires_at: String.t() | nil,
            size_bytes: non_neg_integer()
          }
  end

  @doc """
  Returns the default cache directory path.
  """
  @spec get_cache_dir() :: String.t()
  def get_cache_dir do
    @default_cache_dir
  end

  @doc """
  Returns the cache file path for activity data of a specific repository.
  Legacy function - use get_cache_path/3 for new code.
  """
  @spec get_activity_cache_path(String.t(), keyword()) :: String.t()
  def get_activity_cache_path(repo_name, opts \\ []) do
    get_cache_path(repo_name, "activity", opts)
  end

  @doc """
  Returns the cache file path for a specific repository and category.

  ## Parameters
  - `repo_name`: Repository name
  - `category`: Cache category ("activity", "pr-status", etc.)
  - `opts`: Options including `:cache_dir`

  ## Examples

      iex> Cache.get_cache_path("k21rs001-sotsuron", "activity")
      "~/.cache/registry-manager/activity/k21rs001-sotsuron.json"

      iex> Cache.get_cache_path("k21rs001-sotsuron", "pr-status")
      "~/.cache/registry-manager/pr-status/k21rs001-sotsuron.json"
  """
  @spec get_cache_path(String.t(), String.t(), keyword()) :: String.t()
  def get_cache_path(repo_name, category, opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, get_cache_dir())
    Path.join([cache_dir, category, "#{repo_name}.json"])
  end

  @doc """
  Stores data in cache with TTL.

  ## Options
  - `:cache_dir` - Custom cache directory
  - `:category` - Cache category (default: "activity")
  - `:ttl_hours` - TTL in hours (default: 1)
  - `:ttl_minutes` - TTL in minutes (takes precedence over ttl_hours)
  """
  @spec put(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def put(repo_name, data, opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, get_cache_dir())
    category = Keyword.get(opts, :category, @default_category)
    ttl_hours = calculate_ttl_hours(opts)

    cache_file = get_cache_path(repo_name, category, cache_dir: cache_dir)

    # Ensure cache directory exists
    cache_file
    |> Path.dirname()
    |> File.mkdir_p!()

    now = DateTime.utc_now()
    expires_at = calculate_ttl(now, ttl_hours)

    cache_entry = %{
      "repository" => repo_name,
      "cached_at" => DateTime.to_iso8601(now),
      "expires_at" => DateTime.to_iso8601(expires_at),
      "data" => data
    }

    case Jason.encode(cache_entry, pretty: true) do
      {:ok, json_content} ->
        case File.write(cache_file, json_content) do
          :ok -> :ok
          {:error, reason} -> {:error, {:write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:json_encode_failed, reason}}
    end
  end

  # TTL計算：ttl_minutes が指定されていれば優先、なければ ttl_hours を使用
  defp calculate_ttl_hours(opts) do
    case Keyword.get(opts, :ttl_minutes) do
      nil -> Keyword.get(opts, :ttl_hours, @default_ttl_hours)
      minutes when is_number(minutes) -> minutes / 60
    end
  end

  @doc """
  Retrieves data from cache.
  Returns {:ok, data} if cache is valid, {:error, reason} otherwise.

  ## Options
  - `:cache_dir` - Custom cache directory
  - `:category` - Cache category (default: "activity")
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def get(repo_name, opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, get_cache_dir())
    category = Keyword.get(opts, :category, @default_category)
    cache_file = get_cache_path(repo_name, category, cache_dir: cache_dir)

    if File.exists?(cache_file) do
      read_and_decode_cache(cache_file)
    else
      {:error, :cache_miss}
    end
  end

  defp read_and_decode_cache(cache_file) do
    case File.read(cache_file) do
      {:ok, content} ->
        decode_and_validate_cache(content)

      {:error, _} ->
        {:error, :read_failed}
    end
  end

  defp decode_and_validate_cache(content) do
    case Jason.decode(content) do
      {:ok, cache_entry} ->
        if expired?(cache_entry["expires_at"]) do
          {:error, :cache_expired}
        else
          {:ok, cache_entry["data"]}
        end

      {:error, _} ->
        {:error, :invalid_cache}
    end
  end

  @doc """
  Deletes a specific cache entry.

  ## Options
  - `:cache_dir` - Custom cache directory
  - `:category` - Cache category (default: "activity")
  """
  @spec delete(String.t(), keyword()) :: :ok
  def delete(repo_name, opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, get_cache_dir())
    category = Keyword.get(opts, :category, @default_category)
    cache_file = get_cache_path(repo_name, category, cache_dir: cache_dir)

    if File.exists?(cache_file) do
      File.rm(cache_file)
    end

    :ok
  end

  @doc """
  Clears all cache entries for a specific category.

  ## Options
  - `:cache_dir` - Custom cache directory
  - `:category` - Cache category (default: "activity")
  """
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, get_cache_dir())
    category = Keyword.get(opts, :category, @default_category)
    category_dir = Path.join(cache_dir, category)

    if File.exists?(category_dir) do
      File.rm_rf!(category_dir)
      File.mkdir_p!(category_dir)
    end

    :ok
  end

  @doc """
  Returns status information for a cache entry.

  ## Options
  - `:cache_dir` - Custom cache directory
  - `:category` - Cache category (default: "activity")
  """
  @spec status(String.t(), keyword()) :: {:ok, CacheStatus.t()}
  def status(repo_name, opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, get_cache_dir())
    category = Keyword.get(opts, :category, @default_category)
    cache_file = get_cache_path(repo_name, category, cache_dir: cache_dir)

    if File.exists?(cache_file) do
      build_existing_cache_status(repo_name, cache_file)
    else
      build_missing_cache_status(repo_name)
    end
  end

  @doc """
  Refreshes cache by deleting the entry (forces re-fetch on next access).
  """
  @spec refresh(String.t(), keyword()) :: :ok
  def refresh(repo_name, opts \\ []) do
    delete(repo_name, opts)
  end

  @doc """
  Calculates TTL expiration time.
  """
  @spec calculate_ttl(DateTime.t(), number()) :: DateTime.t()
  def calculate_ttl(base_time, ttl_hours) do
    # round を使用して、エッジケース（例: 4.999分 → 5分）を適切に処理
    ttl_seconds = round(ttl_hours * 60 * 60)
    DateTime.add(base_time, ttl_seconds, :second)
  end

  @doc """
  Checks if a cache entry is expired based on expires_at timestamp.
  """
  @spec expired?(String.t() | nil) :: boolean()
  def expired?(nil), do: true

  def expired?(expires_at_string) do
    case DateTime.from_iso8601(expires_at_string) do
      {:ok, expires_at, _} ->
        DateTime.compare(DateTime.utc_now(), expires_at) == :gt

      {:error, _} ->
        true
    end
  end

  @doc """
  Gets cache statistics for all entries.
  """
  @spec get_cache_stats(keyword()) :: %{
          total_entries: non_neg_integer(),
          total_size_bytes: non_neg_integer(),
          expired_entries: non_neg_integer(),
          valid_entries: non_neg_integer()
        }
  def get_cache_stats(opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, get_cache_dir())
    activity_dir = Path.join(cache_dir, "activity")

    if File.exists?(activity_dir) do
      files =
        File.ls!(activity_dir)
        |> Enum.filter(&String.ends_with?(&1, ".json"))

      stats =
        Enum.reduce(
          files,
          %{total_entries: 0, total_size_bytes: 0, expired_entries: 0, valid_entries: 0},
          &accumulate_cache_file_stats/2
        )

      stats
    else
      %{total_entries: 0, total_size_bytes: 0, expired_entries: 0, valid_entries: 0}
    end
  end

  defp build_existing_cache_status(repo_name, cache_file) do
    with {:ok, content} <- File.read(cache_file),
         {:ok, cache_entry} <- Jason.decode(content) do
      build_valid_cache_status(repo_name, cache_file, cache_entry)
    else
      _ -> build_corrupted_cache_status(repo_name, cache_file)
    end
  end

  defp build_valid_cache_status(repo_name, cache_file, cache_entry) do
    stat = File.stat!(cache_file)

    status = %CacheStatus{
      repository: repo_name,
      exists: true,
      expired: expired?(cache_entry["expires_at"]),
      cached_at: cache_entry["cached_at"],
      expires_at: cache_entry["expires_at"],
      size_bytes: stat.size
    }

    {:ok, status}
  end

  defp build_corrupted_cache_status(repo_name, cache_file) do
    stat = File.stat!(cache_file)

    status = %CacheStatus{
      repository: repo_name,
      exists: true,
      expired: true,
      cached_at: nil,
      expires_at: nil,
      size_bytes: stat.size
    }

    {:ok, status}
  end

  defp build_missing_cache_status(repo_name) do
    status = %CacheStatus{
      repository: repo_name,
      exists: false,
      expired: false,
      cached_at: nil,
      expires_at: nil,
      size_bytes: 0
    }

    {:ok, status}
  end

  defp accumulate_cache_file_stats(file, acc) do
    cache_dir = get_cache_dir()
    activity_dir = Path.join(cache_dir, "activity")
    file_path = Path.join(activity_dir, file)

    if File.exists?(file_path) do
      stat = File.stat!(file_path)
      is_expired = check_cache_expiration(file_path)

      %{
        total_entries: acc.total_entries + 1,
        total_size_bytes: acc.total_size_bytes + stat.size,
        expired_entries: if(is_expired, do: acc.expired_entries + 1, else: acc.expired_entries),
        valid_entries: if(is_expired, do: acc.valid_entries, else: acc.valid_entries + 1)
      }
    else
      # Skip non-existent files
      acc
    end
  end

  defp check_cache_expiration(file_path) do
    with {:ok, content} <- File.read(file_path),
         {:ok, cache_entry} <- Jason.decode(content) do
      expired?(cache_entry["expires_at"])
    else
      _ -> true
    end
  end
end
