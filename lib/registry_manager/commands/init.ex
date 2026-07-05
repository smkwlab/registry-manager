defmodule RegistryManager.Commands.Init do
  @moduledoc """
  レジストリデータリポジトリの bootstrap コマンド

  private リポジトリの作成、空の data/registry.json と README の初期投入、
  ~/.config/registry-manager/config.json の生成を冪等に行う。

  読み取り側（thesis-monitor）のセットアップは thesis-monitor init が担当する。
  """

  alias RegistryManager.Config
  alias RegistryManager.GitHubAPI.Client

  @registry_file_path "data/registry.json"
  @readme_path "README.md"

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
    org = opts[:org] || "smkwlab"
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
        merged = config_path |> File.read!() |> Jason.decode!() |> Map.merge(proposed)
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

  defp write_config(config_path, config, output) do
    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, Jason.encode!(config, pretty: true) <> "\n")
    call(output, :success, "✓ config を書き込みました: #{config_path}")
    :ok
  end

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
