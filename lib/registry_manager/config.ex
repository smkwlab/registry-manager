defmodule RegistryManager.Config do
  @moduledoc """
  Configuration management for registry-manager.

  Handles loading configuration from multiple sources with proper priority:
  1. User config file (~/.config/registry-manager/config.json)
  2. Environment variables
  3. Default values
  """

  # csv_path: optional student-roster CSV for name resolution (nil = disabled)
  # registry_repo: GitHub repository ("owner/repo") holding data/registry.json
  #   (legacy name: data/repositories.json).
  #   Keep this repository PRIVATE when it contains real student data.
  # test_student_ids: student IDs treated as test data by the production
  #   safety check (organization-specific, so empty by default)
  defstruct csv_path: nil,
            registry_repo: nil,
            test_student_ids: [],
            # 意図的なデフォルト: 本ツールは smkwlab がメンテナンスしており、
            # 後方互換のため既定組織を維持する。他組織は config.json または
            # REGISTRY_MANAGER_GITHUB_ORG で上書きする（README 参照）。
            github_org: "smkwlab",
            cache: %{
              enabled: true,
              ttl_hours: 1,
              max_size_mb: 50
            },
            api: %{
              timeout_seconds: 15,
              max_concurrent: 8
            },
            log_level: "info"

  @type cache_config :: %{
          enabled: boolean(),
          ttl_hours: non_neg_integer(),
          max_size_mb: non_neg_integer()
        }

  @type api_config :: %{
          timeout_seconds: non_neg_integer(),
          max_concurrent: non_neg_integer()
        }

  @type t :: %__MODULE__{
          csv_path: String.t() | nil,
          registry_repo: String.t() | nil,
          test_student_ids: [String.t()],
          github_org: String.t(),
          cache: cache_config(),
          api: api_config(),
          log_level: String.t()
        }

  @valid_log_levels ["debug", "info", "warn", "error"]

  @doc """
  Returns default configuration values.
  """
  @spec default_config() :: t()
  def default_config do
    %__MODULE__{}
  end

  @doc """
  Loads configuration from environment variables.
  Returns map with atom keys if environment variables are set or empty map if parsing fails.
  """
  @spec load_env_config() :: %{
          optional(:api) => %{optional(:timeout_seconds) => integer()},
          optional(:cache) => %{
            optional(:enabled) => boolean(),
            optional(:ttl_hours) => integer()
          },
          optional(:csv_path | :github_org | :registry_repo | :data_repo | :log_level) =>
            String.t(),
          optional(:test_student_ids) => [String.t()]
        }
  def load_env_config do
    %{}
    |> put_if_env(:csv_path, "REGISTRY_MANAGER_CSV_PATH")
    |> put_if_env(:github_org, "REGISTRY_MANAGER_GITHUB_ORG")
    |> put_if_env(:registry_repo, "REGISTRY_MANAGER_REGISTRY_REPO")
    |> put_if_env(:data_repo, "REGISTRY_MANAGER_DATA_REPO")
    |> put_test_student_ids_env()
    |> put_if_env(:log_level, "REGISTRY_MANAGER_LOG_LEVEL")
    |> put_cache_env()
    |> put_api_env()
  catch
    :throw, _ -> %{}
  end

  defp put_test_student_ids_env(config) do
    case System.get_env("REGISTRY_MANAGER_TEST_STUDENT_IDS") do
      nil ->
        config

      value ->
        ids = value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        Map.put(config, :test_student_ids, ids)
    end
  end

  defp put_if_env(config, key, env_var) do
    case System.get_env(env_var) do
      nil -> config
      value -> Map.put(config, key, value)
    end
  end

  defp put_cache_env(config) do
    cache_config = %{}

    cache_config =
      cache_config
      |> put_cache_enabled_env()
      |> put_cache_ttl_env()

    if cache_config == %{} do
      config
    else
      Map.put(config, :cache, cache_config)
    end
  end

  defp put_cache_enabled_env(cache_config) do
    case System.get_env("REGISTRY_MANAGER_CACHE_ENABLED") do
      nil -> cache_config
      "true" -> Map.put(cache_config, :enabled, true)
      "false" -> Map.put(cache_config, :enabled, false)
      _ -> throw(:invalid_boolean)
    end
  end

  defp put_cache_ttl_env(cache_config) do
    case System.get_env("REGISTRY_MANAGER_CACHE_TTL_HOURS") do
      nil ->
        cache_config

      value ->
        case Integer.parse(value) do
          {int_value, ""} -> Map.put(cache_config, :ttl_hours, int_value)
          _ -> throw(:invalid_integer)
        end
    end
  end

  defp put_api_env(config) do
    api_config = %{}

    api_config =
      case System.get_env("REGISTRY_MANAGER_API_TIMEOUT") do
        nil ->
          api_config

        value ->
          case Integer.parse(value) do
            {int_value, ""} -> Map.put(api_config, :timeout_seconds, int_value)
            _ -> throw(:invalid_integer)
          end
      end

    if api_config == %{} do
      config
    else
      Map.put(config, :api, api_config)
    end
  end

  @doc """
  Loads user configuration from JSON file.
  Returns map with only explicitly set values if file exists, empty map otherwise.
  """
  @spec load_user_config(String.t()) :: map()
  def load_user_config(config_file_path) do
    if File.exists?(config_file_path) do
      parse_config_file(config_file_path)
    else
      %{}
    end
  end

  # YAML 1.2 は JSON の上位互換なので、YAML パーサ 1 本で
  # config.yml と旧 config.json の両方を読める（issue #18）
  defp parse_config_file(config_file_path) do
    case YamlElixir.read_from_file(config_file_path) do
      {:ok, config} when is_map(config) ->
        config

      _ ->
        IO.puts(:stderr, "Failed to parse config file: #{config_file_path}")
        %{}
    end
  end

  @doc """
  Loads configuration with proper priority:
  User config > Environment variables > Default values
  """
  @spec load_config(String.t() | nil) :: t()
  def load_config(config_file_path \\ nil) do
    config_file_path = config_file_path || resolve_default_config_path()
    default_config = default_config()

    env_config =
      load_env_config()
      |> migrate_legacy_registry_key("environment variable REGISTRY_MANAGER_DATA_REPO")

    user_config =
      load_user_config(config_file_path)
      |> migrate_legacy_registry_key(config_file_path)

    merge_configs([default_config, env_config, user_config])
    |> apply_csv_convention()
  end

  # csv_path 未設定（nil / 空文字列）のとき、規約パス
  # ~/.config/<github_org>/students.csv が存在すればそれを使う（issue #16）。
  # 明示設定（config.json / REGISTRY_MANAGER_CSV_PATH）が常に優先。
  # 名簿 CSV はローカル管理方針のためリポジトリ・レジストリには置かない。
  # load_config の内部実装だが、home を注入したテストのために public にしている。
  @doc false
  @spec apply_csv_convention(t(), String.t() | nil) :: t()
  def apply_csv_convention(config, home \\ System.user_home())

  def apply_csv_convention(%__MODULE__{csv_path: csv} = config, home) when csv in [nil, ""] do
    conventional = safe_conventional_csv_path(config.github_org, home)

    if conventional && File.exists?(conventional) do
      %{config | csv_path: conventional}
    else
      %{config | csv_path: nil}
    end
  end

  def apply_csv_convention(config, _home), do: config

  # github_org / home が使えない環境（未設定・HOME なし）では規約導出をスキップ
  defp safe_conventional_csv_path(github_org, home)
       when is_binary(github_org) and github_org != "" and is_binary(home) do
    conventional_csv_path(github_org, home)
  end

  defp safe_conventional_csv_path(_github_org, _home), do: nil

  @doc """
  Returns the conventional roster CSV path for an organization.
  """
  @spec conventional_csv_path(String.t(), String.t()) :: String.t()
  def conventional_csv_path(github_org, home \\ System.user_home!())
      when is_binary(github_org) and is_binary(home) do
    Path.join([home, ".config", github_org, "students.csv"])
  end

  # 旧キー data_repo を registry_repo へ移行（1 世代の後方互換、issue #8）
  defp migrate_legacy_registry_key(config, source) when is_map(config) do
    legacy = Map.get(config, :data_repo) || Map.get(config, "data_repo")
    new = Map.get(config, :registry_repo) || Map.get(config, "registry_repo")

    cond do
      is_nil(legacy) ->
        config

      is_nil(new) ->
        IO.puts(
          :stderr,
          "warning: config key \"data_repo\" is deprecated, " <>
            "rename it to \"registry_repo\" (#{source})"
        )

        config
        |> Map.drop([:data_repo, "data_repo"])
        |> Map.put(:registry_repo, legacy)

      true ->
        IO.puts(
          :stderr,
          "warning: config key \"data_repo\" is ignored because " <>
            "\"registry_repo\" is set (#{source})"
        )

        Map.drop(config, [:data_repo, "data_repo"])
    end
  end

  @doc """
  Returns the default config file path (annotated YAML, issue #18).
  """
  @spec get_default_config_path() :: String.t()
  def get_default_config_path do
    Path.join(default_config_dir(), "config.yml")
  end

  @doc """
  Returns the legacy JSON config path (one-generation fallback).
  """
  @spec get_legacy_config_path() :: String.t()
  def get_legacy_config_path do
    Path.join(default_config_dir(), "config.json")
  end

  # 探索順: config.yml → 旧 config.json（警告付き 1 世代 fallback）→ config.yml
  # config_dir はテストのために注入可能
  @doc false
  @spec resolve_default_config_path(String.t()) :: String.t()
  def resolve_default_config_path(config_dir \\ default_config_dir()) do
    yml = Path.join(config_dir, "config.yml")
    json = Path.join(config_dir, "config.json")

    cond do
      File.exists?(yml) ->
        yml

      File.exists?(json) ->
        IO.puts(
          :stderr,
          "warning: config file \"config.json\" is deprecated, " <>
            "rename it to \"config.yml\" (#{json})"
        )

        json

      true ->
        yml
    end
  end

  defp default_config_dir do
    Path.join([System.user_home!(), ".config", "registry-manager"])
  end

  @doc """
  Validates configuration values.
  """
  @spec validate_config(t()) :: {:ok, t()} | {:error, String.t()}
  def validate_config(%__MODULE__{} = config) do
    with :ok <- validate_csv_path(config.csv_path),
         :ok <- validate_registry_repo(config.registry_repo),
         :ok <- validate_cache_config(config.cache),
         :ok <- validate_api_config(config.api),
         :ok <- validate_log_level(config.log_level) do
      {:ok, config}
    end
  end

  # nil = CSV integration disabled (name resolution unavailable)
  defp validate_csv_path(nil), do: :ok

  defp validate_csv_path(csv_path) do
    # Skip validation if path is relative (common in tests)
    if String.starts_with?(csv_path, "/") and not File.exists?(csv_path) do
      {:error, "CSV file not found: #{csv_path}"}
    else
      :ok
    end
  end

  # nil = not configured yet; commands needing GitHub data access report it
  defp validate_registry_repo(nil), do: :ok

  defp validate_registry_repo(registry_repo) do
    if Regex.match?(~r{\A[^/\s]+/[^/\s]+\z}, registry_repo) do
      :ok
    else
      {:error, "registry_repo must be in \"owner/repo\" format: #{registry_repo}"}
    end
  end

  defp validate_cache_config(cache) do
    if cache.ttl_hours <= 0 do
      {:error, "Cache TTL must be positive"}
    else
      :ok
    end
  end

  defp validate_api_config(api) do
    if api.timeout_seconds <= 0 do
      {:error, "API timeout must be positive"}
    else
      :ok
    end
  end

  defp validate_log_level(log_level) do
    if log_level in @valid_log_levels do
      :ok
    else
      {:error, "Invalid log level: #{log_level}"}
    end
  end

  @doc """
  Converts a map to Config struct, handling nested structures.
  """
  @spec map_to_struct(map()) :: t()
  def map_to_struct(map) when is_map(map) do
    config = struct(__MODULE__, [])

    Enum.reduce(map, config, fn
      {"csv_path", value}, acc when is_binary(value) ->
        %{acc | csv_path: value}

      {:csv_path, value}, acc when is_binary(value) ->
        %{acc | csv_path: value}

      {"github_org", value}, acc when is_binary(value) ->
        %{acc | github_org: value}

      {:github_org, value}, acc when is_binary(value) ->
        %{acc | github_org: value}

      {"registry_repo", value}, acc when is_binary(value) ->
        %{acc | registry_repo: value}

      {:registry_repo, value}, acc when is_binary(value) ->
        %{acc | registry_repo: value}

      {"test_student_ids", value}, acc when is_list(value) ->
        %{acc | test_student_ids: Enum.filter(value, &is_binary/1)}

      {:test_student_ids, value}, acc when is_list(value) ->
        %{acc | test_student_ids: Enum.filter(value, &is_binary/1)}

      {"log_level", value}, acc when is_binary(value) ->
        %{acc | log_level: value}

      {:log_level, value}, acc when is_binary(value) ->
        %{acc | log_level: value}

      {"cache", cache_map}, acc when is_map(cache_map) ->
        cache_config = merge_cache_config(acc.cache, cache_map)
        %{acc | cache: cache_config}

      {:cache, cache_map}, acc when is_map(cache_map) ->
        cache_config = merge_cache_config(acc.cache, cache_map)
        %{acc | cache: cache_config}

      {"api", api_map}, acc when is_map(api_map) ->
        api_config = merge_api_config(acc.api, api_map)
        %{acc | api: api_config}

      {:api, api_map}, acc when is_map(api_map) ->
        api_config = merge_api_config(acc.api, api_map)
        %{acc | api: api_config}

      {_key, _value}, acc ->
        acc
    end)
  end

  defp merge_cache_config(base_cache, cache_map) do
    Enum.reduce(cache_map, base_cache, fn
      {"enabled", value}, acc when is_boolean(value) ->
        %{acc | enabled: value}

      {:enabled, value}, acc when is_boolean(value) ->
        %{acc | enabled: value}

      {"ttl_hours", value}, acc when is_integer(value) ->
        %{acc | ttl_hours: value}

      {:ttl_hours, value}, acc when is_integer(value) ->
        %{acc | ttl_hours: value}

      {"max_size_mb", value}, acc when is_integer(value) ->
        %{acc | max_size_mb: value}

      {:max_size_mb, value}, acc when is_integer(value) ->
        %{acc | max_size_mb: value}

      {_key, _value}, acc ->
        acc
    end)
  end

  defp merge_api_config(base_api, api_map) do
    Enum.reduce(api_map, base_api, fn
      {"timeout_seconds", value}, acc when is_integer(value) ->
        %{acc | timeout_seconds: value}

      {:timeout_seconds, value}, acc when is_integer(value) ->
        %{acc | timeout_seconds: value}

      {"max_concurrent", value}, acc when is_integer(value) ->
        %{acc | max_concurrent: value}

      {:max_concurrent, value}, acc when is_integer(value) ->
        %{acc | max_concurrent: value}

      {_key, _value}, acc ->
        acc
    end)
  end

  @doc """
  Merges multiple configurations with later configs taking priority.
  """
  @spec merge_configs([t() | map()]) :: t()
  def merge_configs(configs) do
    Enum.reduce(configs, %__MODULE__{}, fn config, acc ->
      merge_single_config(acc, config)
    end)
  end

  defp merge_single_config(base, %__MODULE__{} = config) do
    %{
      base
      | csv_path: config.csv_path,
        github_org: config.github_org,
        registry_repo: config.registry_repo,
        test_student_ids: config.test_student_ids,
        cache: merge_cache_struct(base.cache, config.cache),
        api: merge_api_struct(base.api, config.api),
        log_level: config.log_level
    }
  end

  defp merge_single_config(base, config) when is_map(config) do
    # 直接マップの値を使用してマージ（atom key と string key の両方をサポート）
    base
    |> merge_if_present(config, :csv_path, "csv_path")
    |> merge_if_present(config, :github_org, "github_org")
    |> merge_if_present(config, :registry_repo, "registry_repo")
    |> merge_if_present(config, :test_student_ids, "test_student_ids")
    |> merge_if_present(config, :log_level, "log_level")
    |> merge_cache_map(config)
    |> merge_api_map(config)
  end

  defp merge_if_present(base, config, atom_key, string_key) do
    # atom key を優先、次に string key をチェック
    case Map.get(config, atom_key) || Map.get(config, string_key) do
      nil -> base
      value -> Map.put(base, atom_key, value)
    end
  end

  defp merge_cache_map(base, config) do
    case Map.get(config, :cache) || Map.get(config, "cache") do
      nil ->
        base

      cache_map ->
        merged_cache = merge_cache_config(base.cache, cache_map)
        %{base | cache: merged_cache}
    end
  end

  defp merge_api_map(base, config) do
    case Map.get(config, :api) || Map.get(config, "api") do
      nil ->
        base

      api_map ->
        merged_api = merge_api_config(base.api, api_map)
        %{base | api: merged_api}
    end
  end

  defp merge_cache_struct(base, new) do
    %{base | enabled: new.enabled, ttl_hours: new.ttl_hours, max_size_mb: new.max_size_mb}
  end

  defp merge_api_struct(base, new) do
    %{base | timeout_seconds: new.timeout_seconds, max_concurrent: new.max_concurrent}
  end
end
