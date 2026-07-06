defmodule RegistryManager.Commands.InitTest do
  use ExUnit.Case, async: true

  alias RegistryManager.Commands.Init

  @not_found {:error, "GitHub API error (404): Not Found"}

  defp output_stub do
    parent = self()

    %{
      puts: fn msg -> send(parent, {:out, :puts, msg}) end,
      info: fn msg -> send(parent, {:out, :info, msg}) end,
      success: fn msg -> send(parent, {:out, :success, msg}) end,
      warn: fn msg -> send(parent, {:out, :warn, msg}) end,
      error: fn msg -> send(parent, {:out, :error, msg}) end
    }
  end

  defp collect_output(kind) do
    receive do
      {:out, ^kind, msg} -> [msg | collect_output(kind)]
    after
      0 -> []
    end
  end

  defp tmp_config_path do
    Path.join(
      System.tmp_dir!(),
      "rm-init-config-#{System.unique_integer([:positive])}.json"
    )
  end

  # 何も存在しない状態を表す api スタブ（作成系は成功）
  defp api_bootstrap_stub(parent) do
    fn
      :get, "/user", _ ->
        {:ok, %{"login" => "toshi0806"}}

      :get, "/repos/testorg/test-registry", _ ->
        @not_found

      :post, "/orgs/testorg/repos", body ->
        send(parent, {:api, :create_repo, body})
        {:ok, %{"full_name" => "testorg/test-registry"}}

      :get, "/repos/testorg/test-registry/contents/data/registry.json", _ ->
        @not_found

      :put, "/repos/testorg/test-registry/contents/data/registry.json", body ->
        send(parent, {:api, :create_registry_file, body})
        {:ok, %{}}

      :get, "/repos/testorg/test-registry/contents/README.md", _ ->
        @not_found

      :put, "/repos/testorg/test-registry/contents/README.md", body ->
        send(parent, {:api, :create_readme, body})
        {:ok, %{}}
    end
  end

  describe "run/3 bootstrap" do
    test "creates repo, registry file, README, and config when nothing exists" do
      config_path = tmp_config_path()
      on_exit(fn -> File.rm(config_path) end)

      deps = %{api: api_bootstrap_stub(self()), output: output_stub(), config_path: config_path}

      assert {:ok, _} = Init.run(["testorg/test-registry"], [], deps)

      assert_received {:api, :create_repo, body}
      assert body[:private] == true
      assert body[:name] == "test-registry"

      assert_received {:api, :create_registry_file, file_body}
      assert Base.decode64!(file_body[:content]) =~ "{}"

      assert_received {:api, :create_readme, readme_body}
      readme = Base.decode64!(readme_body[:content])
      assert String.starts_with?(readme, "# test-registry\n")
      refute readme =~ ~r/^\s+#/m
      assert readme =~ "private"

      {:ok, config} = YamlElixir.read_from_string(File.read!(config_path))
      assert config["registry_repo"] == "testorg/test-registry"
      assert config["github_org"] == "testorg"
    end

    test "creates under /user/repos when the owner is the authenticated user" do
      config_path = tmp_config_path()
      on_exit(fn -> File.rm(config_path) end)
      parent = self()

      api = fn
        :get, "/user", _ ->
          {:ok, %{"login" => "toshi0806"}}

        :get, "/repos/toshi0806/my-registry", _ ->
          @not_found

        :post, "/user/repos", body ->
          send(parent, {:api, :create_user_repo, body})
          {:ok, %{}}

        :post, "/orgs/" <> _, _ ->
          flunk("must use /user/repos for the authenticated user")

        :get, _, _ ->
          @not_found

        :put, _, _ ->
          {:ok, %{}}
      end

      deps = %{api: api, output: output_stub(), config_path: config_path}

      assert {:ok, _} = Init.run(["toshi0806/my-registry"], [], deps)
      assert_received {:api, :create_user_repo, _}
    end

    test "is idempotent: skips creation when everything already exists" do
      config_path = tmp_config_path()
      on_exit(fn -> File.rm(config_path) end)

      api = fn
        :get, "/user", _ -> {:ok, %{"login" => "toshi0806"}}
        :get, "/repos/testorg/test-registry", _ -> {:ok, %{"private" => true}}
        :get, "/repos/testorg/test-registry/contents/" <> _, _ -> {:ok, %{"sha" => "abc"}}
        :post, path, _ -> flunk("must not create anything: POST #{path}")
        :put, path, _ -> flunk("must not create anything: PUT #{path}")
      end

      deps = %{api: api, output: output_stub(), config_path: config_path}

      assert {:ok, _} = Init.run(["testorg/test-registry"], [], deps)
      assert Enum.any?(collect_output(:info), &(&1 =~ "スキップ"))
    end

    test "warns when the existing repo is public" do
      config_path = tmp_config_path()
      on_exit(fn -> File.rm(config_path) end)

      api = fn
        :get, "/user", _ -> {:ok, %{"login" => "toshi0806"}}
        :get, "/repos/testorg/test-registry", _ -> {:ok, %{"private" => false}}
        :get, "/repos/testorg/test-registry/contents/" <> _, _ -> {:ok, %{"sha" => "abc"}}
      end

      deps = %{api: api, output: output_stub(), config_path: config_path}

      assert {:ok, _} = Init.run(["testorg/test-registry"], [], deps)
      assert Enum.any?(collect_output(:warn), &(&1 =~ "private"))
    end
  end

  describe "run/3 config handling" do
    test "does not overwrite an existing config without --force" do
      config_path = tmp_config_path()

      File.write!(
        config_path,
        Jason.encode!(%{"registry_repo" => "old/repo", "csv_path" => "/x.csv"})
      )

      on_exit(fn -> File.rm(config_path) end)

      deps = %{api: api_bootstrap_stub(self()), output: output_stub(), config_path: config_path}

      assert {:ok, _} = Init.run(["testorg/test-registry"], [], deps)

      {:ok, config} = YamlElixir.read_from_string(File.read!(config_path))
      assert config["registry_repo"] == "old/repo"
      assert Enum.any?(collect_output(:warn), &(&1 =~ "--force"))
    end

    test "writes an annotated YAML config (issue #18)" do
      config_path = tmp_config_path()
      on_exit(fn -> File.rm(config_path) end)

      deps = %{api: api_bootstrap_stub(self()), output: output_stub(), config_path: config_path}

      assert {:ok, _} = Init.run(["testorg/test-registry"], [], deps)

      content = File.read!(config_path)
      assert content =~ ~r/^# /m
      assert content =~ ~r/^github_org: /m
      assert content =~ ~r/^registry_repo: /m

      {:ok, parsed} = YamlElixir.read_from_string(content)
      assert parsed["registry_repo"] == "testorg/test-registry"
      assert parsed["github_org"] == "testorg"
    end

    test "suggests migration when only the legacy config.json exists" do
      dir = Path.join(System.tmp_dir!(), "rm-init-mig-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      File.write!(Path.join(dir, "config.json"), ~s({"csv_path": "/x.csv"}))
      config_path = Path.join(dir, "config.yml")

      deps = %{api: api_bootstrap_stub(self()), output: output_stub(), config_path: config_path}

      assert {:ok, _} = Init.run(["testorg/test-registry"], [], deps)

      refute File.exists?(config_path)
      assert Enum.any?(collect_output(:warn), &(&1 =~ "--force"))
    end

    test "migrates the legacy config.json into config.yml with --force" do
      dir = Path.join(System.tmp_dir!(), "rm-init-mig-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      File.write!(Path.join(dir, "config.json"), ~s({"csv_path": "/x.csv"}))
      config_path = Path.join(dir, "config.yml")

      deps = %{api: api_bootstrap_stub(self()), output: output_stub(), config_path: config_path}

      assert {:ok, _} = Init.run(["testorg/test-registry"], [force: true], deps)

      {:ok, parsed} = YamlElixir.read_from_string(File.read!(config_path))
      assert parsed["registry_repo"] == "testorg/test-registry"
      assert parsed["csv_path"] == "/x.csv"
    end

    test "recovers from a corrupt existing config with --force" do
      config_path = tmp_config_path()
      File.write!(config_path, "{ broken json")
      on_exit(fn -> File.rm(config_path) end)

      deps = %{api: api_bootstrap_stub(self()), output: output_stub(), config_path: config_path}

      assert {:ok, _} = Init.run(["testorg/test-registry"], [force: true], deps)

      {:ok, config} = YamlElixir.read_from_string(File.read!(config_path))
      assert config["registry_repo"] == "testorg/test-registry"
      assert Enum.any?(collect_output(:warn), &(&1 =~ "解析できません"))
    end

    test "merges keys into the existing config with --force, preserving others" do
      config_path = tmp_config_path()

      File.write!(
        config_path,
        Jason.encode!(%{"registry_repo" => "old/repo", "csv_path" => "/x.csv"})
      )

      on_exit(fn -> File.rm(config_path) end)

      deps = %{api: api_bootstrap_stub(self()), output: output_stub(), config_path: config_path}

      assert {:ok, _} = Init.run(["testorg/test-registry"], [force: true], deps)

      {:ok, config} = YamlElixir.read_from_string(File.read!(config_path))
      assert config["registry_repo"] == "testorg/test-registry"
      assert config["github_org"] == "testorg"
      assert config["csv_path"] == "/x.csv"
    end
  end

  describe "run/3 failure guidance" do
    test "returns an error instead of raising when the config path is not writable" do
      # 非 root では作成できないパス
      config_path = "/nonexistent-root-dir/registry-manager/config.json"

      deps = %{api: api_bootstrap_stub(self()), output: output_stub(), config_path: config_path}

      assert {:error, :config_write_failed} = Init.run(["testorg/test-registry"], [], deps)
      assert Enum.any?(collect_output(:error), &(&1 =~ "config"))
    end

    test "fails with gh auth guidance when authentication is unavailable" do
      config_path = tmp_config_path()

      api = fn
        :get, "/user", _ -> {:error, "GitHub CLI authentication failed. Run 'gh auth login'"}
      end

      deps = %{api: api, output: output_stub(), config_path: config_path}

      assert {:error, :auth_failed} = Init.run(["testorg/test-registry"], [], deps)
      assert Enum.any?(collect_output(:error), &(&1 =~ "gh auth login"))
    end

    test "fails with permission guidance when org repo creation is rejected" do
      config_path = tmp_config_path()

      api = fn
        :get, "/user", _ ->
          {:ok, %{"login" => "toshi0806"}}

        :get, "/repos/testorg/test-registry", _ ->
          @not_found

        :post, "/orgs/testorg/repos", _ ->
          {:error, "GitHub API error (403): Must have admin rights"}
      end

      deps = %{api: api, output: output_stub(), config_path: config_path}

      assert {:error, :repo_create_failed} = Init.run(["testorg/test-registry"], [], deps)
      assert Enum.any?(collect_output(:error), &(&1 =~ "権限"))
    end

    test "rejects an invalid repository argument" do
      deps = %{api: fn _, _, _ -> flunk("no api call expected") end, output: output_stub()}

      assert {:error, :invalid_repo} = Init.run(["not-a-repo-format"], [], deps)
    end
  end
end
