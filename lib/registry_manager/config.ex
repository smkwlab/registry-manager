defmodule RegistryManager.Config do
  @moduledoc """
  Configuration management for registry-manager.

  Handles loading configuration from multiple sources with proper priority
  (ECOSYSTEM.md の Tool Configuration Conventions に準拠):
  1. CLI flags (--registry-repo / --org / --config)
  2. Environment variables
  3. User config file (~/.config/registry-manager/config.yml)
  4. Default values

  レイヤの読み込み・マージと規約ヘルパ(owner 導出・名簿 CSV・owner/repo
  検証)の機構は `ToolKit.Config.Layers` に委譲し、本モジュールは
  registry-manager の設定スキーマ(struct)と規約の適用順序を持つ。
  """

  alias ToolKit.Config.Layers

  # csv_path: optional student-roster CSV for name resolution (nil = disabled)
  # registry_repo: GitHub repository ("owner/repo") holding data/registry.json
  #   (legacy name: data/repositories.json).
  #   Keep this repository PRIVATE when it contains real student data.
  # test_student_ids: student IDs treated as test data by the production
  #   safety check (organization-specific, so empty by default)
  defstruct csv_path: nil,
            registry_repo: nil,
            test_student_ids: [],
            # github_org は既定値を持たない（issue #45）。未設定時は registry_repo
            # の owner から導出する（init が owner を org に流用する規約を実行時にも
            # 適用）。明示設定（config.yml / REGISTRY_MANAGER_GITHUB_ORG / --org）が
            # 優先。registry_repo も無い場合は nil のままで、学生リポジトリ操作時に
            # 明示エラーになる（他組織への静かな誤対象を防止）。
            github_org: nil,
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
          github_org: String.t() | nil,
          cache: cache_config(),
          api: api_config(),
          log_level: String.t()
        }

  @valid_log_levels ["debug", "info", "warn", "error"]

  @env_prefix "REGISTRY_MANAGER"

  # 環境変数 spec（ToolKit.Config.Layers.read_env）。変数名は
  # REGISTRY_MANAGER_<キー経路の大文字連結>。api.timeout_seconds のみ
  # 歴史的経緯で REGISTRY_MANAGER_API_TIMEOUT（末端名の差し替え）
  @env_spec %{
    csv_path: :string,
    github_org: :string,
    registry_repo: :string,
    test_student_ids: :string_list,
    log_level: :string,
    cache: %{enabled: :boolean, ttl_hours: :integer},
    api: %{timeout_seconds: {:integer, "TIMEOUT"}}
  }

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
          optional(:csv_path | :github_org | :registry_repo | :log_level) => String.t(),
          optional(:test_student_ids) => [String.t()]
        }
  def load_env_config do
    case Layers.read_env(@env_prefix, @env_spec) do
      {:ok, config} -> config
      # 不正な値（boolean / integer の変換失敗）は env 層全体を無視する
      {:error, _message} -> %{}
    end
  end

  @doc """
  Loads user configuration from the annotated YAML file.
  Returns map with only explicitly set values if file exists, empty map otherwise.

  YAML 1.2 は JSON の上位互換なので、YAML パーサ 1 本で config.yml と
  旧 config.json の両方を読める（issue #18）。
  """
  @spec load_user_config(String.t()) :: map()
  def load_user_config(config_file_path) do
    case Layers.load_file(config_file_path) do
      {:ok, config} ->
        config

      {:error, {:parse_error, path}} ->
        IO.puts(:stderr, "Failed to parse config file: #{path}")
        %{}
    end
  end

  @doc """
  Loads configuration with proper priority:
  CLI flags > Environment variables > User config > Default values

  CLI フラグは CLI 層が `Application.put_env(:registry_manager, :cli_overrides, %{...})`
  （設定ファイルパスは `:config_path`）として登録し、ここで最終レイヤとして
  マージされる。
  """
  @spec load_config(String.t() | nil) :: t()
  def load_config(config_file_path \\ nil) do
    path =
      config_file_path ||
        Application.get_env(:registry_manager, :config_path) ||
        get_default_config_path()

    user_config = load_user_config(path)
    env_config = load_env_config()
    cli_overrides = Application.get_env(:registry_manager, :cli_overrides, %{})

    [user_config, env_config, cli_overrides]
    |> merge_configs()
    |> apply_github_org_convention()
    |> apply_csv_convention()
  end

  # github_org 未設定（nil / 空文字列）のとき、registry_repo の owner を既定として
  # 使う（issue #45）。明示設定（config.yml / REGISTRY_MANAGER_GITHUB_ORG / --org）は
  # マージ時点で既に入っているため常に優先される。registry_repo も未設定なら nil の
  # ままにし、GitHubAPI.build_full_repo_name/1 が呼ばれた時点で明示エラーにさせる。
  @doc false
  @spec apply_github_org_convention(t()) :: t()
  def apply_github_org_convention(%__MODULE__{} = config) do
    %{config | github_org: Layers.derive_github_org(config.github_org, config.registry_repo)}
  end

  @github_org_error ~s|github_org is not configured. Set "github_org" (or "registry_repo", | <>
                      "whose owner is used) in ~/.config/registry-manager/config.yml, " <>
                      "REGISTRY_MANAGER_GITHUB_ORG, or use --org."

  @doc """
  設定済みの github_org を返す。未設定（nil / 空）なら明示エラーを返す（issue #45）。
  `owner/repo` 名を組み立てる呼び出し側が使い、他組織への静かな誤対象（`/repo`）を防ぐ。
  """
  @spec require_github_org() :: {:ok, String.t()} | {:error, String.t()}
  def require_github_org do
    case load_config().github_org do
      org when org in [nil, ""] -> {:error, @github_org_error}
      org -> {:ok, org}
    end
  end

  # csv_path 未設定（nil / 空文字列）のとき、規約パス
  # ~/.config/<github_org>/students.csv が存在すればそれを使う（issue #16）。
  # 明示設定（config.yml / REGISTRY_MANAGER_CSV_PATH）が常に優先。
  # 名簿 CSV はローカル管理方針のためリポジトリ・レジストリには置かない。
  # load_config の内部実装だが、home を注入したテストのために public にしている。
  @doc false
  @spec apply_csv_convention(t(), String.t() | nil) :: t()
  def apply_csv_convention(config, home \\ System.user_home())

  def apply_csv_convention(%__MODULE__{csv_path: csv} = config, home) when csv in [nil, ""] do
    %{config | csv_path: Layers.find_conventional_csv(config.github_org, home)}
  end

  def apply_csv_convention(config, _home), do: config

  @doc """
  Returns the conventional roster CSV path for an organization.
  """
  @spec conventional_csv_path(String.t(), String.t()) :: String.t()
  defdelegate conventional_csv_path(github_org, home \\ System.user_home!()), to: Layers

  @doc """
  Returns the default config file path (annotated YAML, issue #18).

  旧 config.json は読み込まない（公開前に fallback を持たない決定）。
  移行は `mv config.json config.yml`（YAML 1.2 ⊃ JSON なのでそのまま有効）。
  """
  @spec get_default_config_path() :: String.t()
  def get_default_config_path do
    Layers.default_config_path("registry-manager")
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
  @doc """
  Returns true when the value is in "owner/repo" format.
  """
  @spec valid_registry_repo?(String.t()) :: boolean()
  defdelegate valid_registry_repo?(value), to: Layers, as: :valid_owner_repo?

  defp validate_registry_repo(nil), do: :ok

  defp validate_registry_repo(registry_repo) do
    if valid_registry_repo?(registry_repo) do
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
    merge_configs([map])
  end

  @doc """
  Merges multiple configurations with later configs taking priority.

  マージ規則は `ToolKit.Config.Layers.merge/1` に従う（nil は既存値を
  上書きしない・入れ子 map は再帰マージ）。map レイヤは defaults を
  テンプレートにキーを正規化する（string / atom キー両対応、未知キーは
  無視）。
  """
  @spec merge_configs([t() | map()]) :: t()
  def merge_configs(configs) do
    defaults = Map.from_struct(%__MODULE__{})
    layers = Enum.map(configs, &config_layer(&1, defaults))

    struct(__MODULE__, Layers.merge([defaults | layers]))
  end

  defp config_layer(%__MODULE__{} = config, _defaults), do: Map.from_struct(config)
  defp config_layer(map, defaults) when is_map(map), do: Layers.normalize_keys(map, defaults)
end
