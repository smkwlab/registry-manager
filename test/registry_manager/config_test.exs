defmodule RegistryManager.ConfigTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias RegistryManager.Config

  @config_dir Path.join(System.tmp_dir!(), "registry_manager_test_config")
  @config_file Path.join(@config_dir, "config.json")

  setup do
    # テスト用の設定ディレクトリを作成
    File.mkdir_p!(@config_dir)

    # 既存の設定ファイルがあれば削除
    if File.exists?(@config_file) do
      File.rm!(@config_file)
    end

    # 環境変数をクリア
    System.delete_env("REGISTRY_MANAGER_CSV_PATH")
    System.delete_env("REGISTRY_MANAGER_GITHUB_ORG")
    System.delete_env("REGISTRY_MANAGER_REGISTRY_REPO")
    System.delete_env("REGISTRY_MANAGER_DATA_REPO")
    System.delete_env("REGISTRY_MANAGER_TEST_STUDENT_IDS")
    System.delete_env("REGISTRY_MANAGER_CACHE_ENABLED")
    System.delete_env("REGISTRY_MANAGER_CACHE_TTL_HOURS")
    System.delete_env("REGISTRY_MANAGER_API_TIMEOUT")
    System.delete_env("REGISTRY_MANAGER_LOG_LEVEL")

    on_exit(fn ->
      # テスト後にクリーンアップ
      if File.exists?(@config_file) do
        File.rm!(@config_file)
      end

      if File.exists?(@config_dir) do
        File.rmdir(@config_dir)
      end
    end)

    {:ok, config_dir: @config_dir, config_file: @config_file}
  end

  describe "default_config/0" do
    test "returns default configuration values" do
      config = Config.default_config()

      # CSV integration is optional and disabled by default
      assert config.csv_path == nil
      # Registry data repository must be configured explicitly
      assert config.registry_repo == nil
      assert config.test_student_ids == []
      assert config.github_org == "smkwlab"
      assert config.cache.enabled == true
      assert config.cache.ttl_hours == 1
      assert config.cache.max_size_mb == 50
      assert config.api.timeout_seconds == 15
      assert config.api.max_concurrent == 8
      assert config.log_level == "info"
    end
  end

  describe "registry_repo key (issue #8)" do
    test "map_to_struct sets registry_repo from string and atom keys" do
      assert Config.map_to_struct(%{"registry_repo" => "org/reg"}).registry_repo == "org/reg"
      assert Config.map_to_struct(%{registry_repo: "org/reg"}).registry_repo == "org/reg"
    end

    test "load_env_config reads REGISTRY_MANAGER_REGISTRY_REPO" do
      System.put_env("REGISTRY_MANAGER_REGISTRY_REPO", "org/registry-data")

      config = Config.load_env_config()
      assert config.registry_repo == "org/registry-data"
    end

    test "validates registry_repo format" do
      config = %{Config.default_config() | registry_repo: "org/repo"}
      assert {:ok, _} = Config.validate_config(config)

      config = %{Config.default_config() | registry_repo: "missing-org-part"}

      assert {:error, "registry_repo must be in \"owner/repo\" format: missing-org-part"} =
               Config.validate_config(config)
    end
  end

  describe "load_env_config/0" do
    test "loads configuration from environment variables" do
      System.put_env("REGISTRY_MANAGER_CSV_PATH", "/custom/path.csv")
      System.put_env("REGISTRY_MANAGER_GITHUB_ORG", "custom_org")
      System.put_env("REGISTRY_MANAGER_TEST_STUDENT_IDS", "k99rs001, k99rs002")
      System.put_env("REGISTRY_MANAGER_CACHE_ENABLED", "false")
      System.put_env("REGISTRY_MANAGER_CACHE_TTL_HOURS", "2")
      System.put_env("REGISTRY_MANAGER_API_TIMEOUT", "30")
      System.put_env("REGISTRY_MANAGER_LOG_LEVEL", "debug")

      config = Config.load_env_config()

      assert config.csv_path == "/custom/path.csv"
      assert config.github_org == "custom_org"
      assert config.test_student_ids == ["k99rs001", "k99rs002"]
      assert config.cache.enabled == false
      assert config.cache.ttl_hours == 2
      assert config.api.timeout_seconds == 30
      assert config.log_level == "debug"
    end

    test "returns empty map when no environment variables are set" do
      config = Config.load_env_config()
      assert config == %{}
    end

    test "handles invalid boolean values gracefully" do
      System.put_env("REGISTRY_MANAGER_CACHE_ENABLED", "invalid")

      config = Config.load_env_config()
      assert config == %{}
    end

    test "handles invalid integer values gracefully" do
      System.put_env("REGISTRY_MANAGER_CACHE_TTL_HOURS", "invalid")

      config = Config.load_env_config()
      assert config == %{}
    end
  end

  describe "load_user_config/1" do
    test "loads configuration from JSON file", %{config_file: config_file} do
      user_config = %{
        "csv_path" => "/user/path.csv",
        "github_org" => "user_org",
        "registry_repo" => "user_org/student-registry",
        "test_student_ids" => ["k99rs001"],
        "cache" => %{
          "enabled" => false,
          "ttl_hours" => 3
        },
        "api" => %{
          "timeout_seconds" => 45
        },
        "log_level" => "warn"
      }

      File.write!(config_file, Jason.encode!(user_config))

      config = Config.load_user_config(config_file)

      # load_user_config は raw map を返すようになった
      assert config["csv_path"] == "/user/path.csv"
      assert config["github_org"] == "user_org"
      assert config["registry_repo"] == "user_org/student-registry"
      assert config["test_student_ids"] == ["k99rs001"]
      assert config["cache"]["enabled"] == false
      assert config["cache"]["ttl_hours"] == 3
      assert config["api"]["timeout_seconds"] == 45
      assert config["log_level"] == "warn"
    end

    test "returns empty map when config file does not exist" do
      non_existent_file = Path.join(System.tmp_dir!(), "non_existent.json")
      config = Config.load_user_config(non_existent_file)
      assert config == %{}
    end

    test "returns empty map when config file contains invalid JSON", %{config_file: config_file} do
      File.write!(config_file, "invalid json")

      assert capture_io(:stderr, fn ->
               config = Config.load_user_config(config_file)
               assert config == %{}
             end) =~ "Failed to parse config file"
    end
  end

  describe "csv_path convention (issue #16)" do
    defp make_home do
      home = Path.join(System.tmp_dir!(), "rm-conv-home-#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      on_exit(fn -> File.rm_rf!(home) end)
      home
    end

    test "conventional_csv_path derives from github_org" do
      assert Config.conventional_csv_path("myorg", "/home/x") ==
               "/home/x/.config/myorg/students.csv"
    end

    test "uses the conventional path when csv_path is unset and the file exists" do
      home = make_home()
      conventional = Path.join([home, ".config", "testorg", "students.csv"])
      File.mkdir_p!(Path.dirname(conventional))
      File.write!(conventional, "header\n")

      config = %Config{csv_path: nil, github_org: "testorg"}

      assert Config.apply_csv_convention(config, home).csv_path == conventional
    end

    test "keeps csv_path nil when the conventional file does not exist" do
      home = make_home()
      config = %Config{csv_path: nil, github_org: "testorg"}

      assert Config.apply_csv_convention(config, home).csv_path == nil
    end

    test "an explicit csv_path wins over the conventional file" do
      home = make_home()
      conventional = Path.join([home, ".config", "testorg", "students.csv"])
      File.mkdir_p!(Path.dirname(conventional))
      File.write!(conventional, "header\n")

      config = %Config{csv_path: "/explicit/path.csv", github_org: "testorg"}

      assert Config.apply_csv_convention(config, home).csv_path == "/explicit/path.csv"
    end

    test "an empty-string csv_path is treated as unset" do
      home = make_home()
      conventional = Path.join([home, ".config", "testorg", "students.csv"])
      File.mkdir_p!(Path.dirname(conventional))
      File.write!(conventional, "header\n")

      config = %Config{csv_path: "", github_org: "testorg"}

      assert Config.apply_csv_convention(config, home).csv_path == conventional
    end

    test "an empty-string csv_path normalizes to nil when no conventional file exists" do
      home = make_home()
      config = %Config{csv_path: "", github_org: "testorg"}

      assert Config.apply_csv_convention(config, home).csv_path == nil
    end

    test "skips the convention when github_org is nil or empty" do
      home = make_home()
      conventional = Path.join([home, ".config", "testorg", "students.csv"])
      File.mkdir_p!(Path.dirname(conventional))
      File.write!(conventional, "header\n")

      assert Config.apply_csv_convention(%Config{csv_path: nil, github_org: nil}, home).csv_path ==
               nil

      assert Config.apply_csv_convention(%Config{csv_path: nil, github_org: ""}, home).csv_path ==
               nil
    end

    test "skips the convention when the home directory is unavailable" do
      config = %Config{csv_path: nil, github_org: "testorg"}

      assert Config.apply_csv_convention(config, nil).csv_path == nil
    end

    test "load_config applies the convention (no file for an unlikely org)", %{
      config_file: config_file
    } do
      File.write!(
        config_file,
        Jason.encode!(%{"github_org" => "no-such-org-#{System.unique_integer([:positive])}"})
      )

      config = Config.load_config(config_file)

      assert config.csv_path == nil
    end
  end

  describe "precedence: CLI > env > user config > default (issue #38)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "rm_precedence_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "config.yml")

      on_exit(fn ->
        Application.delete_env(:registry_manager, :cli_overrides)
        Application.delete_env(:registry_manager, :config_path)
        File.rm_rf!(dir)
      end)

      {:ok, path: path}
    end

    test "environment variables beat the user config file", %{path: path} do
      File.write!(path, "registry_repo: file/repo\n")
      System.put_env("REGISTRY_MANAGER_REGISTRY_REPO", "env/repo")

      config = Config.load_config(path)

      assert config.registry_repo == "env/repo"
    end

    test "cli overrides beat environment variables", %{path: path} do
      File.write!(path, "registry_repo: file/repo\n")
      System.put_env("REGISTRY_MANAGER_REGISTRY_REPO", "env/repo")
      Application.put_env(:registry_manager, :cli_overrides, %{registry_repo: "cli/repo"})

      config = Config.load_config(path)

      assert config.registry_repo == "cli/repo"
    end

    test "user config file still beats defaults", %{path: path} do
      File.write!(path, "github_org: fileorg\n")

      config = Config.load_config(path)

      assert config.github_org == "fileorg"
    end

    test "a single cache env var does not clobber file cache settings", %{path: path} do
      File.write!(path, """
      cache:
        enabled: false
        max_size_mb: 99
      """)

      System.put_env("REGISTRY_MANAGER_CACHE_TTL_HOURS", "5")

      config = Config.load_config(path)

      assert config.cache.enabled == false
      assert config.cache.max_size_mb == 99
      assert config.cache.ttl_hours == 5
    end

    test "config_path application env overrides the default path", %{path: path} do
      File.write!(path, "registry_repo: viapath/repo\n")
      Application.put_env(:registry_manager, :config_path, path)

      config = Config.load_config()

      assert config.registry_repo == "viapath/repo"
    end
  end

  describe "valid_registry_repo?/1" do
    test "accepts owner/repo and rejects other shapes" do
      assert Config.valid_registry_repo?("owner/repo")
      refute Config.valid_registry_repo?("owner")
      refute Config.valid_registry_repo?("owner/repo/extra")
      refute Config.valid_registry_repo?("owner /repo")
    end
  end

  describe "config file format (issue #18)" do
    test "default config path is config.yml" do
      assert String.ends_with?(Config.get_default_config_path(), "registry-manager/config.yml")
    end

    test "load_user_config parses annotated YAML" do
      path = Path.join(System.tmp_dir!(), "rm-yaml-#{System.unique_integer([:positive])}.yml")

      File.write!(path, """
      # comment line
      github_org: yamlorg
      registry_repo: yamlorg/thesis-student-registry
      test_student_ids: [k99rs998, k99rs999]
      """)

      on_exit(fn -> File.rm(path) end)

      config = Config.load_user_config(path)
      assert config["github_org"] == "yamlorg"
      assert config["registry_repo"] == "yamlorg/thesis-student-registry"
      assert config["test_student_ids"] == ["k99rs998", "k99rs999"]
    end

    test "load_user_config still parses legacy JSON content (YAML superset)" do
      path = Path.join(System.tmp_dir!(), "rm-json-#{System.unique_integer([:positive])}.json")
      File.write!(path, ~s({"github_org": "jsonorg", "cache": {"enabled": false}}))
      on_exit(fn -> File.rm(path) end)

      config = Config.load_user_config(path)
      assert config["github_org"] == "jsonorg"
      assert config["cache"]["enabled"] == false
    end
  end

  describe "load_config/1" do
    test "merges configurations with correct priority", %{config_file: config_file} do
      # 既存の環境変数をクリア
      System.delete_env("REGISTRY_MANAGER_GITHUB_ORG")
      System.delete_env("REGISTRY_MANAGER_CACHE_TTL_HOURS")

      # ユーザー設定ファイル（環境変数で指定される項目は含まない）
      user_config = %{
        "csv_path" => "/user/path.csv",
        "cache" => %{
          "enabled" => false
        }
      }

      File.write!(config_file, Jason.encode!(user_config))

      # 環境変数設定
      System.put_env("REGISTRY_MANAGER_GITHUB_ORG", "env_org")
      System.put_env("REGISTRY_MANAGER_CACHE_TTL_HOURS", "5")

      try do
        config = Config.load_config(config_file)

        # 優先順位: ユーザー設定 > 環境変数 > デフォルト
        # ユーザー設定が優先
        assert config.csv_path == "/user/path.csv"
        # 環境変数のみ設定
        assert config.github_org == "env_org"
        # ユーザー設定が優先
        assert config.cache.enabled == false
        # 環境変数のみ設定
        assert config.cache.ttl_hours == 5
        # デフォルト値のみ
        assert config.api.timeout_seconds == 15
      after
        # テスト後に環境変数をクリア
        System.delete_env("REGISTRY_MANAGER_GITHUB_ORG")
        System.delete_env("REGISTRY_MANAGER_CACHE_TTL_HOURS")
      end
    end

    test "works with default config file path when file doesn't exist" do
      non_existent_file = Path.join(System.tmp_dir!(), "non_existent.yml")
      config = Config.load_config(non_existent_file)

      assert config.registry_repo == nil
      assert config.github_org == "smkwlab"
    end

    test "csv_path defaults to nil when no CSV is configured" do
      # github_org を実在しない org にして、実行環境の規約ファイルに依存しない
      path = Path.join(System.tmp_dir!(), "rm-detcsv-#{System.unique_integer([:positive])}.yml")
      File.write!(path, "github_org: no-such-org-#{System.unique_integer([:positive])}\n")
      on_exit(fn -> File.rm(path) end)

      config = Config.load_config(path)

      assert config.csv_path == nil
    end
  end

  describe "get_default_config_path/0" do
    test "returns path in user's config directory" do
      path = Config.get_default_config_path()
      assert String.ends_with?(path, ".config/registry-manager/config.yml")
    end
  end

  describe "validate_config/1" do
    test "validates valid configuration" do
      config = Config.default_config()
      assert {:ok, ^config} = Config.validate_config(config)
    end

    test "validates CSV path existence" do
      config = %{Config.default_config() | csv_path: "/non/existent/path.csv"}

      assert {:error, "CSV file not found: /non/existent/path.csv"} =
               Config.validate_config(config)
    end

    test "accepts nil CSV path (name resolution disabled)" do
      config = %{Config.default_config() | csv_path: nil}
      assert {:ok, ^config} = Config.validate_config(config)
    end

    test "validates cache TTL range" do
      config = %{
        Config.default_config()
        | cache: %{Config.default_config().cache | ttl_hours: -1}
      }

      assert {:error, "Cache TTL must be positive"} = Config.validate_config(config)
    end

    test "validates API timeout range" do
      config = %{
        Config.default_config()
        | api: %{Config.default_config().api | timeout_seconds: 0}
      }

      assert {:error, "API timeout must be positive"} = Config.validate_config(config)
    end

    test "validates log level" do
      config = %{Config.default_config() | log_level: "invalid"}
      assert {:error, "Invalid log level: invalid"} = Config.validate_config(config)
    end
  end

  describe "struct conversion" do
    test "converts map to struct properly" do
      map_config = %{
        "csv_path" => "/test/path.csv",
        "github_org" => "test_org",
        "registry_repo" => "test_org/registry-data",
        "test_student_ids" => ["k99rs001", "k99rs002"],
        "cache" => %{
          "enabled" => true,
          "ttl_hours" => 2,
          "max_size_mb" => 100
        },
        "api" => %{
          "timeout_seconds" => 20,
          "max_concurrent" => 4
        },
        "log_level" => "debug"
      }

      config = Config.map_to_struct(map_config)

      assert %Config{} = config
      assert config.csv_path == "/test/path.csv"
      assert config.github_org == "test_org"
      assert config.registry_repo == "test_org/registry-data"
      assert config.test_student_ids == ["k99rs001", "k99rs002"]
      assert config.cache.enabled == true
      assert config.cache.ttl_hours == 2
      assert config.cache.max_size_mb == 100
      assert config.api.timeout_seconds == 20
      assert config.api.max_concurrent == 4
      assert config.log_level == "debug"
    end
  end
end
