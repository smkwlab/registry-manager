defmodule RegistryManager.GitHubAPI do
  @moduledoc """
  GitHub API オーケストレーション

  外部依存を Client に委譲し、データ変換を Parser に委譲することで、
  ビジネスロジックに集中したテスト可能な設計を実現。
  """

  alias RegistryManager.Config
  alias RegistryManager.GitHubAPI.{Client, Parser}
  alias RegistryManager.Repository.Compatibility

  # レジストリファイルは data/registry.json に固定
  # （旧名 repositories.json の互換は持たない — 公開前に後方互換を全廃、issue #21）
  @registry_file_path "data/registry.json"

  # レジストリデータリポジトリは設定必須（Config.registry_repo）
  defp registry_repo do
    case Config.load_config().registry_repo do
      nil ->
        {:error,
         ~s|registry_repo is not configured. Set "registry_repo" ("owner/repo") in | <>
           "~/.config/registry-manager/config.yml or REGISTRY_MANAGER_REGISTRY_REPO."}

      repo ->
        {:ok, repo}
    end
  end

  @doc """
  現在のレジストリファイル（registry.json、旧名 repositories.json）の内容を取得
  """
  def get_repositories_json do
    if use_mock?() do
      apply(RegistryManager.Test.GitHubAPIMock, :get_repositories_json, [])
    else
      get_repositories_json_impl()
    end
  end

  @doc """
  レジストリファイルを更新してコミット
  """
  def update_repositories_json(new_data, current_sha, commit_message) do
    # Safety check for test data
    case validate_test_data_safety(new_data) do
      :ok ->
        if use_mock?() do
          apply(
            RegistryManager.Test.GitHubAPIMock,
            :update_repositories_json,
            [new_data, current_sha, commit_message]
          )
        else
          update_repositories_json_impl(new_data, current_sha, commit_message)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  GitHubリポジトリの情報を取得
  """
  def get_repository_info(repo_name) do
    with {:ok, {full_repo_name, _org}} <- ensure_full_repo_name(repo_name) do
      if use_mock?() do
        apply(RegistryManager.Test.GitHubAPIMock, :get_repository_info, [full_repo_name])
      else
        Client.get_repository_info(full_repo_name)
      end
    end
  end

  @doc """
  リポジトリの実際の開発者を特定
  組織所有の場合はコミット履歴から最も活発な開発者を特定
  """
  def get_actual_developer(repo_name, opts \\ []) do
    with {:ok, {full_repo_name, org}} <- ensure_full_repo_name(repo_name) do
      if use_mock?() do
        apply(RegistryManager.Test.GitHubAPIMock, :get_actual_developer, [full_repo_name, opts])
      else
        fetch_actual_developer(full_repo_name, org, opts)
      end
    end
  end

  @doc """
  リポジトリの open Pull Request 一覧を取得（archive 前のクローズ対象）。
  戻り値は `{:ok, [%{number: integer, title: String.t()}]}`。
  """
  def list_open_pull_requests(repo_name) do
    with {:ok, {full_repo_name, _org}} <- ensure_full_repo_name(repo_name) do
      if use_mock?() do
        apply(RegistryManager.Test.GitHubAPIMock, :list_open_pull_requests, [full_repo_name])
      else
        fetch_open_pull_requests(full_repo_name)
      end
    end
  end

  @doc """
  Issue / Pull Request にコメントを投稿
  """
  def create_issue_comment(repo_name, issue_number, body) do
    with {:ok, {full_repo_name, _org}} <- ensure_full_repo_name(repo_name) do
      if use_mock?() do
        apply(RegistryManager.Test.GitHubAPIMock, :create_issue_comment, [
          full_repo_name,
          issue_number,
          body
        ])
      else
        Client.create_issue_comment(full_repo_name, issue_number, body)
      end
    end
  end

  @doc """
  Pull Request をクローズ
  """
  def close_pull_request(repo_name, pr_number) do
    with {:ok, {full_repo_name, _org}} <- ensure_full_repo_name(repo_name) do
      if use_mock?() do
        apply(RegistryManager.Test.GitHubAPIMock, :close_pull_request, [
          full_repo_name,
          pr_number
        ])
      else
        Client.close_pull_request(full_repo_name, pr_number)
      end
    end
  end

  @doc """
  リポジトリを archive
  """
  def archive_repository(repo_name) do
    with {:ok, {full_repo_name, _org}} <- ensure_full_repo_name(repo_name) do
      if use_mock?() do
        apply(RegistryManager.Test.GitHubAPIMock, :archive_repository, [full_repo_name])
      else
        Client.archive_repository(full_repo_name)
      end
    end
  end

  @doc """
  リポジトリ名を `owner/repo` 形式に揃え、解決した owner も併せて返す。

  既に `owner/repo` 形式ならそのまま返し（冪等）、owner は名前から取る。短名なら
  設定の github_org を前置する。

  **接頭辞の付与はこの 1 か所に寄せている。** 呼び出し側が先に付けてから渡すと
  二重付与（`owner/owner/repo`）になり、実運用の `add` は常に 404 を返していた
  （issue #100）。mock 分岐も付与の後に置いてあるので、テストはこの関数を必ず通る。

  github_org が未設定（nil / 空）なら明示エラーにする（issue #45）。config は
  github_org を registry_repo の owner から導出するため、通常は registry_repo を
  設定していれば埋まる。どちらも未設定のまま学生リポジトリ操作を呼んだ場合に、
  他組織への静かな誤対象を防ぐ。owner が空の `"/repo"` も同じ理由で拒否する。

  解決した org も返すのは、呼び出し側での再取得（load_config 二重呼び出し）を避けるため。

  `defp` ではなく `def` にしているのは、**この不変条件（冪等であること）を直接
  テストできるようにするため**。間接テストだけでは足りないことが issue #100 で
  実証されている — mock 分岐が付与の手前にあった間、mock のキーは正しい値を
  持っていたのにテストは付与の行を一度も実行しなかった。`@doc false` にすると
  呼び出し可能性は変わらないまま、この不変条件の説明だけが隠れるので採らない。

  このモジュールの外から呼ぶ必要は現時点では無い。リポジトリ名を扱う公開関数
  （`get_repository_info/1` ほか）はいずれも内部でこれを通すので、呼び出し側は
  短名のまま渡せばよく、**先に接頭辞を付けてはいけない**。

  それらの公開関数は、この関数が返した `{:error, reason}` を加工せずそのまま
  返す（github_org 未設定や不正な名前は、API を叩く前にここで止まる）。
  """
  @spec ensure_full_repo_name(String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, String.t()}
  def ensure_full_repo_name(repo_name) when is_binary(repo_name) do
    case String.split(repo_name, "/", parts: 2) do
      [owner, _repo] when owner != "" ->
        {:ok, {repo_name, owner}}

      [_empty_owner, _repo] ->
        {:error, ~s|invalid repository name "#{repo_name}": the owner before "/" is empty|}

      [_short_name] ->
        with {:ok, org} <- Config.require_github_org() do
          {:ok, {"#{org}/#{repo_name}", org}}
        end
    end
  end

  # プライベート実装関数

  # :ok 側は Parser.extract_actual_developer/2 の戻り値をそのまま返すため、
  # この関数は {:ok, developer} と {:error, reason} の両方を返し得る
  # （コミットが空・著者が全員自動化アカウント、などで後者になる）。
  defp fetch_actual_developer(full_repo_name, org, opts) do
    case Client.get_actual_developer(full_repo_name, opts) do
      {:ok, commits} -> Parser.extract_actual_developer(commits, org)
      {:error, _reason} = error -> error
    end
  end

  defp fetch_open_pull_requests(full_repo_name) do
    case Client.get_repository_pull_requests(full_repo_name, state: "open") do
      {:ok, response} ->
        {:ok, Enum.map(response, fn pr -> %{number: pr["number"], title: pr["title"]} end)}

      {:error, _reason} = error ->
        error
    end
  end

  defp get_repositories_json_impl do
    with {:ok, repo} <- registry_repo(),
         {:ok, response} <- Client.get_file_contents(repo, @registry_file_path),
         {:ok, {data, sha}} <- Parser.decode_file_response(response) do
      # データ読み込み時に正規化を適用
      normalized_data = Compatibility.normalize_repositories(data)
      {:ok, {normalized_data, sha}}
    end
  end

  defp update_repositories_json_impl(new_data, current_sha, commit_message) do
    with {:ok, repo} <- registry_repo(),
         {:ok, encoded_content} <- Parser.encode_file_content(new_data),
         {:ok, _response} <-
           Client.update_file_contents(
             repo,
             @registry_file_path,
             encoded_content,
             current_sha,
             commit_message
           ) do
      {:ok, "Repository updated successfully"}
    end
  end

  defp validate_test_data_safety(new_data) do
    production_mode = Parser.detect_environment_mode() == :production
    test_student_ids = Config.load_config().test_student_ids

    new_data
    |> Map.keys()
    |> Enum.find_value(fn repo_name ->
      case Parser.validate_test_safety(repo_name, production_mode, test_student_ids) do
        :ok -> nil
        {:error, reason} -> reason
      end
    end)
    |> case do
      nil -> :ok
      error_reason -> {:error, error_reason}
    end
  end

  defp use_mock? do
    Parser.detect_environment_mode() == :test
  end
end
