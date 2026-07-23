defmodule RegistryManager.Cache do
  @moduledoc """
  Cache management for registry-manager.

  Provides caching functionality for GitHub API responses, particularly
  activity information that is expensive to fetch repeatedly.

  The cache mechanism (TTL envelope, atomic writes, per-category directories)
  is provided by `ToolKit.Cache`. This module keeps the registry-manager
  vocabulary (repository names, `activity` / `pr-status` categories, hour/minute
  TTLs, the `CacheStatus` struct) and delegates the actual file I/O to it.

  Cache structure:
  ~/.cache/registry-manager/
  ├── activity/           # list --activity 用キャッシュ
  │   └── {repo_name}.json
  ├── pr-status/          # pr-status 用キャッシュ
  │   └── {repo_name}.json
  """

  alias ToolKit.Cache, as: ToolKitCache

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
    ToolKitCache.put(repo_name, data, put_opts(opts))
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
    ToolKitCache.get(repo_name, dir_opts(opts))
  end

  @doc """
  Deletes a specific cache entry.

  ## Options
  - `:cache_dir` - Custom cache directory
  - `:category` - Cache category (default: "activity")
  """
  @spec delete(String.t(), keyword()) :: :ok
  def delete(repo_name, opts \\ []) do
    ToolKitCache.delete(repo_name, dir_opts(opts))
  end

  @doc """
  Clears all cache entries for a specific category.

  ## Options
  - `:cache_dir` - Custom cache directory
  - `:category` - Cache category (default: "activity")
  """
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    ToolKitCache.clear(dir_opts(opts))
  end

  @doc """
  Returns status information for a cache entry.

  ## Options
  - `:cache_dir` - Custom cache directory
  - `:category` - Cache category (default: "activity")
  """
  @spec status(String.t(), keyword()) :: {:ok, CacheStatus.t()}
  def status(repo_name, opts \\ []) do
    status =
      repo_name
      |> ToolKitCache.status(dir_opts(opts))
      |> to_cache_status()

    {:ok, status}
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
    DateTime.add(base_time, ttl_seconds(ttl_hours), :second)
  end

  @doc """
  Checks if a cache entry is expired based on expires_at timestamp.
  """
  @spec expired?(String.t() | nil) :: boolean()
  defdelegate expired?(expires_at_string), to: ToolKitCache

  @doc """
  Gets cache statistics for all entries in the activity category.
  """
  @spec get_cache_stats(keyword()) :: %{
          total_entries: non_neg_integer(),
          total_size_bytes: non_neg_integer(),
          expired_entries: non_neg_integer(),
          valid_entries: non_neg_integer()
        }
  def get_cache_stats(opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, get_cache_dir())
    ToolKitCache.stats(cache_dir: cache_dir, category: "activity")
  end

  # --- 内部関数 ---

  # ToolKit.Cache は TTL を秒で受け取る。registry-manager の
  # ttl_hours / ttl_minutes 語彙を秒へ変換する(ttl_minutes が優先)。
  defp put_opts(opts) do
    Keyword.put(dir_opts(opts), :ttl, ttl_from_opts(opts))
  end

  defp dir_opts(opts) do
    [
      cache_dir: Keyword.get(opts, :cache_dir, get_cache_dir()),
      category: Keyword.get(opts, :category, @default_category)
    ]
  end

  defp ttl_from_opts(opts) do
    case Keyword.get(opts, :ttl_minutes) do
      nil -> ttl_seconds(Keyword.get(opts, :ttl_hours, @default_ttl_hours))
      minutes when is_number(minutes) -> round(minutes * 60)
    end
  end

  defp ttl_seconds(ttl_hours), do: round(ttl_hours * 60 * 60)

  defp to_cache_status(%ToolKitCache.Status{} = status) do
    %CacheStatus{
      repository: status.key,
      exists: status.exists,
      expired: status.expired,
      cached_at: status.cached_at,
      expires_at: status.expires_at,
      size_bytes: status.size_bytes
    }
  end
end
