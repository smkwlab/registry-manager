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
      # Data repository must be configured explicitly
      assert config.data_repo == nil
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

  describe "load_env_config/0" do
    test "loads configuration from environment variables" do
      System.put_env("REGISTRY_MANAGER_CSV_PATH", "/custom/path.csv")
      System.put_env("REGISTRY_MANAGER_GITHUB_ORG", "custom_org")
      System.put_env("REGISTRY_MANAGER_DATA_REPO", "custom_org/data-repo")
      System.put_env("REGISTRY_MANAGER_TEST_STUDENT_IDS", "k99rs001, k99rs002")
      System.put_env("REGISTRY_MANAGER_CACHE_ENABLED", "false")
      System.put_env("REGISTRY_MANAGER_CACHE_TTL_HOURS", "2")
      System.put_env("REGISTRY_MANAGER_API_TIMEOUT", "30")
      System.put_env("REGISTRY_MANAGER_LOG_LEVEL", "debug")

      config = Config.load_env_config()

      assert config.csv_path == "/custom/path.csv"
      assert config.github_org == "custom_org"
      assert config.data_repo == "custom_org/data-repo"
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
        "data_repo" => "user_org/student-registry",
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
      assert config["data_repo"] == "user_org/student-registry"
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
      non_existent_file = Path.join(System.tmp_dir!(), "non_existent.json")
      config = Config.load_config(non_existent_file)

      # デフォルト値が返される
      assert config.csv_path == nil
      assert config.data_repo == nil
      assert config.github_org == "smkwlab"
    end
  end

  describe "get_default_config_path/0" do
    test "returns path in user's config directory" do
      path = Config.get_default_config_path()
      assert String.ends_with?(path, ".config/registry-manager/config.json")
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

    test "validates data_repo format" do
      config = %{Config.default_config() | data_repo: "org/repo"}
      assert {:ok, ^config} = Config.validate_config(config)

      config = %{Config.default_config() | data_repo: "missing-org-part"}

      assert {:error, "data_repo must be in \"owner/repo\" format: missing-org-part"} =
               Config.validate_config(config)
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
        "data_repo" => "test_org/registry-data",
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
      assert config.data_repo == "test_org/registry-data"
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
