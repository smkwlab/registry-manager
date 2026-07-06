defmodule RegistryManager.Commands.Init do
  @moduledoc """
  レジストリデータリポジトリの bootstrap コマンド

  private リポジトリの作成、空の data/registry.json と README の初期投入、
  ~/.config/registry-manager/config.yml（注釈付き YAML）の生成を冪等に行う。
  旧 config.json のみが存在する場合は --force で config.yml へ移行できる。

  読み取り側（thesis-monitor）のセットアップは thesis-monitor init が担当する。
  """

  alias RegistryManager.Config
  alias RegistryManager.GitHubAPI.Client

  @registry_file_path "data/registry.json"
  @readme_path "README.md"

  # 既定組織は Config の既定値と同じ意図（本ツールの保守元）。他組織は
  # --org または owner/repo 引数で指定する
  @default_org "smkwlab"

  @initial_registry_content "{}\n"

  def run(args, opts, deps \\ %{}) do
    api = deps[:api] || (&default_api/3)
    output = deps[:output] || default_output()
    config_path = deps[:config_path] || Config.get_default_config_path()

    with {:ok, repo} <- resolve_repo(args, opts, output),
         {:ok, login} <- check_auth(api, output),
         :ok <- ensure_repo(repo, login, api, output),
         :ok <- ensure_file(repo, @registry_file_path, initial_registry(), api, output),
         :ok <- ensure_file(repo, @readme_path, initial_readme(repo), api, output),
         :ok <- ensure_config(repo, opts, config_path, output) do
      show_next_steps(repo, output)
      {:ok, repo}
    end
  end

  # --- 対象リポジトリの解決 ---

  defp resolve_repo(args, opts, output) do
    org = opts[:org] || @default_org
    repo = List.first(args) || "#{org}/thesis-student-registry"

    if Regex.match?(~r{\A[^/\s]+/[^/\s]+\z}, repo) do
      {:ok, repo}
    else
      call(output, :error, "リポジトリは owner/repo 形式で指定してください: #{repo}")
      {:error, :invalid_repo}
    end
  end

  # --- 事前チェック（gh 認証） ---

  defp check_auth(api, output) do
    case api.(:get, "/user", nil) do
      {:ok, %{"login" => login}} ->
        call(output, :success, "✓ GitHub 認証 (#{login})")
        {:ok, login}

      {:error, reason} ->
        call(output, :error, "GitHub 認証に失敗しました: #{reason}\ngh auth login でログインしてください")
        {:error, :auth_failed}
    end
  end

  # --- リポジトリ作成（冪等） ---

  defp ensure_repo(repo, login, api, output) do
    case api.(:get, "/repos/#{repo}", nil) do
      {:ok, info} ->
        call(output, :info, "リポジトリ #{repo} は既に存在します（作成をスキップ）")
        warn_if_public(repo, info, output)
        :ok

      {:error, reason} ->
        if Client.not_found_error?(reason) do
          create_repo(repo, login, api, output)
        else
          call(output, :error, "リポジトリ確認に失敗: #{reason}")
          {:error, :repo_check_failed}
        end
    end
  end

  defp warn_if_public(repo, %{"private" => false}, output) do
    call(
      output,
      :warn,
      "#{repo} は public です。学生データを扱う前に必ず private に変更してください"
    )
  end

  defp warn_if_public(_repo, _info, _output), do: :ok

  defp create_repo(repo, login, api, output) do
    [owner, name] = String.split(repo, "/")

    create_path =
      if owner == login do
        "/user/repos"
      else
        "/orgs/#{owner}/repos"
      end

    body = %{name: name, private: true, description: "Student repository registry data"}

    case api.(:post, create_path, body) do
      {:ok, _} ->
        call(output, :success, "✓ private リポジトリ #{repo} を作成しました")
        :ok

      {:error, reason} ->
        call(
          output,
          :error,
          "リポジトリ作成に失敗: #{reason}\n" <>
            "組織 #{owner} でのリポジトリ作成権限を確認してください"
        )

        {:error, :repo_create_failed}
    end
  end

  # --- 初期ファイル投入（冪等） ---

  defp ensure_file(repo, path, content, api, output) do
    case api.(:get, "/repos/#{repo}/contents/#{path}", nil) do
      {:ok, _} ->
        call(output, :info, "#{path} は既に存在します（作成をスキップ）")
        :ok

      {:error, reason} ->
        if Client.not_found_error?(reason) do
          create_file(repo, path, content, api, output)
        else
          call(output, :error, "#{path} の確認に失敗: #{reason}")
          {:error, :file_check_failed}
        end
    end
  end

  defp create_file(repo, path, content, api, output) do
    body = %{
      message: "Initialize #{path}",
      content: Base.encode64(content)
    }

    case api.(:put, "/repos/#{repo}/contents/#{path}", body) do
      {:ok, _} ->
        call(output, :success, "✓ #{path} を作成しました")
        :ok

      {:error, reason} ->
        call(output, :error, "#{path} の作成に失敗: #{reason}")
        {:error, :file_create_failed}
    end
  end

  defp initial_registry, do: @initial_registry_content

  defp initial_readme(repo) do
    [owner, name] = String.split(repo, "/")

    """
    # #{name}

    学生リポジトリレジストリのデータリポジトリ（registry-manager で管理）。

    - 本体: `data/registry.json`
    - 書き込み: [registry-manager](https://github.com/smkwlab/registry-manager)
    - 読み取り・監視: [thesis-monitor](https://github.com/smkwlab/thesis-monitor)

    **注意**: 学生の個人情報を含み得るため、このリポジトリは必ず private を維持してください。
    （組織: #{owner}）
    """
  end

  # --- config 生成（冪等） ---

  defp ensure_config(repo, opts, config_path, output) do
    [owner, _name] = String.split(repo, "/")
    org = opts[:org] || owner
    proposed = %{"github_org" => org, "registry_repo" => repo}

    cond do
      not File.exists?(config_path) ->
        write_config(config_path, proposed, output)

      opts[:force] ->
        merged = Map.merge(read_existing_config(config_path, output), proposed)
        write_config(config_path, merged, output)

      true ->
        call(
          output,
          :warn,
          "config は既に存在します: #{config_path}（--force で上書き）\n" <>
            "  適用されなかった値: #{Jason.encode!(proposed)}"
        )

        :ok
    end
  end

  # --force 時のマージ元。壊れたファイルは警告して空扱い（proposed のみで書き直す）
  defp read_existing_config(config_path, output) do
    case YamlElixir.read_from_file(config_path) do
      {:ok, config} when is_map(config) ->
        config

      _ ->
        call(output, :warn, "既存の config を解析できません（--force 指定のため新しい値で書き直します）: #{config_path}")
        %{}
    end
  end

  defp write_config(config_path, config, output) do
    with :ok <- File.mkdir_p(Path.dirname(config_path)),
         :ok <- File.write(config_path, annotated_yaml(config)) do
      call(output, :success, "✓ config を書き込みました: #{config_path}")
      :ok
    else
      {:error, reason} ->
        call(output, :error, "config の書き込みに失敗しました: #{config_path} (#{reason})")
        {:error, :config_write_failed}
    end
  end

  # 注釈付き YAML（issue #18）。registry_repo は writer の書き込み先なので
  # 規約導出させず常に有効行で書く
  defp annotated_yaml(config) do
    """
    # Generated by `registry-manager init`
    # レジストリデータリポジトリ（owner/repo）。書き込み先のため明示必須
    # 名簿 CSV は未設定時 ~/.config/<github_org>/students.csv を規約として参照（存在時のみ）
    # csv_path: /path/to/students.csv
    """ <> encode_yaml(config)
  end

  defp encode_yaml(map) do
    map
    |> Enum.sort()
    |> Enum.map_join("", fn {k, v} -> encode_yaml_entry(k, v, "") end)
  end

  defp encode_yaml_entry(key, value, indent) when is_map(value) do
    "#{indent}#{key}:\n" <>
      (value
       |> Enum.sort()
       |> Enum.map_join("", fn {k, v} -> encode_yaml_entry(k, v, indent <> "  ") end))
  end

  defp encode_yaml_entry(key, value, indent) when is_list(value) do
    "#{indent}#{key}: [#{Enum.map_join(value, ", ", &yaml_scalar/1)}]\n"
  end

  defp encode_yaml_entry(key, value, indent) do
    "#{indent}#{key}: #{yaml_scalar(value)}\n"
  end

  # 安全な文字集合（org 名・repo 名・学籍番号などが該当）はクォートせず
  # 素の YAML スカラーで書き、それ以外は inspect のダブルクォートで安全側に倒す
  defp yaml_scalar(value) when is_binary(value) do
    if value =~ ~r/\A[A-Za-z0-9_.\/-]+\z/ do
      value
    else
      inspect(value)
    end
  end

  defp yaml_scalar(value), do: to_string(value)

  # --- 仕上げ ---

  defp show_next_steps(repo, output) do
    call(
      output,
      :puts,
      "\nNext:\n" <>
        "  registry-manager list            # レジストリの確認\n" <>
        "  thesis-monitor init              # 読み取り側（監視ツール）のセットアップ\n" <>
        "  （registry_repo: #{repo}）"
    )
  end

  # --- helpers ---

  defp default_api(method, path, body) do
    with {:ok, token} <- Client.get_github_token() do
      options = if body, do: [token: token, body: body], else: [token: token]
      Client.send_request(method, "https://api.github.com" <> path, options)
    end
  end

  defp default_output do
    %{
      puts: &IO.puts/1,
      info: &IO.puts("ℹ #{&1}"),
      success: &IO.puts("✅ #{&1}"),
      warn: &IO.puts("⚠️  #{&1}"),
      error: &IO.puts(:stderr, "❌ #{&1}")
    }
  end

  defp call(output, fun, msg) when is_map(output), do: output[fun].(msg)
end
