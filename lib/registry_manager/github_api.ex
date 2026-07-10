defmodule RegistryManager.GitHubAPI do
  @moduledoc """
  GitHub API オーケストレーション

  外部依存を Client に委譲し、データ変換を Parser に委譲することで、
  ビジネスロジックに集中したテスト可能な設計を実現。
  """

  alias RegistryManager.Config
  alias RegistryManager.GitHubAPI.{Client, Parser}
  alias RegistryManager.Repository.Compatibility

  require Logger

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
    if use_mock?() do
      apply(RegistryManager.Test.GitHubAPIMock, :get_repository_info, [repo_name])
    else
      get_repository_info_impl(repo_name)
    end
  end

  @doc """
  GitHubリポジトリの最終活動時刻を取得
  """
  def get_repository_activity(repo_name, opts \\ []) do
    if use_mock?() do
      apply(RegistryManager.Test.GitHubAPIMock, :get_repository_activity, [repo_name])
    else
      get_repository_activity_impl(repo_name, opts)
    end
  end

  @doc """
  リポジトリの実際の開発者を特定
  組織所有の場合はコミット履歴から最も活発な開発者を特定
  """
  def get_actual_developer(repo_name, opts \\ []) do
    if use_mock?() do
      apply(RegistryManager.Test.GitHubAPIMock, :get_actual_developer, [repo_name, opts])
    else
      get_actual_developer_impl(repo_name, opts)
    end
  end

  @doc """
  リポジトリのプルリクエスト情報を取得
  """
  def get_repository_pull_requests(repo_name, opts \\ []) do
    if use_mock?() do
      apply(RegistryManager.Test.GitHubAPIMock, :get_repository_pull_requests, [repo_name, opts])
    else
      get_repository_pull_requests_impl(repo_name, opts)
    end
  end

  @doc """
  プルリクエストのレビュー情報を取得
  """
  def get_pull_request_reviews(repo_name, pr_number, opts \\ []) do
    if use_mock?() do
      apply(RegistryManager.Test.GitHubAPIMock, :get_pull_request_reviews, [
        repo_name,
        pr_number,
        opts
      ])
    else
      get_pull_request_reviews_impl(repo_name, pr_number, opts)
    end
  end

  @doc """
  プルリクエストの保留中のレビューリクエストを取得
  """
  def get_pull_request_requested_reviewers(repo_name, pr_number, opts \\ []) do
    if use_mock?() do
      apply(RegistryManager.Test.GitHubAPIMock, :get_pull_request_requested_reviewers, [
        repo_name,
        pr_number,
        opts
      ])
    else
      get_pull_request_requested_reviewers_impl(repo_name, pr_number, opts)
    end
  end

  # プライベート実装関数

  # github_org が未設定（nil / 空）なら明示エラーにする（issue #45）。
  # config は github_org を registry_repo の owner から導出するため、通常は
  # registry_repo を設定していれば埋まる。どちらも未設定のまま学生リポジトリ操作を
  # 呼んだ場合に、他組織への静かな誤対象（"/repo" への API 呼び出し）を防ぐ。
  @doc false
  defp build_full_repo_name(repo_name) do
    case Config.load_config().github_org do
      org when org in [nil, ""] ->
        {:error,
         ~s|github_org is not configured. Set "github_org" (or "registry_repo") in | <>
           "~/.config/registry-manager/config.yml, REGISTRY_MANAGER_GITHUB_ORG, or use --org."}

      org ->
        {:ok, "#{org}/#{repo_name}"}
    end
  end

  defp get_repository_info_impl(repo_name) do
    with {:ok, full_repo_name} <- build_full_repo_name(repo_name),
         {:ok, response} <- Client.get_repository_info(full_repo_name) do
      {:ok, response}
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

  defp get_repository_activity_impl(repo_name, opts) do
    owner_only = Keyword.get(opts, :owner_only, false)

    if owner_only do
      get_owner_activity_impl(repo_name)
    else
      get_general_activity_impl(repo_name)
    end
  end

  defp get_general_activity_impl(repo_name) do
    with {:ok, full_repo_name} <- build_full_repo_name(repo_name),
         {:ok, response} <- Client.get_repository_info(full_repo_name),
         {:ok, activity_time} <- Parser.extract_repository_activity(response) do
      {:ok, activity_time}
    end
  end

  defp get_owner_activity_impl(repo_name) do
    # 常にregistryデータから取得（リポジトリ名からの学生ID抽出は不可能）
    with {:ok, full_repo_name} <- build_full_repo_name(repo_name) do
      get_owner_activity_from_registry(repo_name, full_repo_name)
    end
  end

  defp get_owner_activity_from_registry(repo_name, full_repo_name) do
    with {:ok, {registry_data, _sha}} <- get_repositories_json(),
         {:ok, repo_info} <- get_repository_info_from_registry(registry_data, repo_name),
         {:ok, owner_activities} <- get_all_owners_activity(repo_info, full_repo_name) do
      {:ok, owner_activities}
    else
      {:error, reason} ->
        Logger.debug(
          "Failed to get owner activity from registry for #{repo_name}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp get_repository_info_from_registry(registry_data, repo_name) do
    case Map.get(registry_data, repo_name) do
      nil -> {:error, "Repository not found in registry"}
      repo_info -> {:ok, repo_info}
    end
  end

  # 複数オーナーのアクティビティを取得
  defp get_all_owners_activity(repo_info, full_repo_name) do
    owners = Compatibility.get_all_github_usernames(repo_info)

    if owners == [] do
      {:error, "No github_username in registry"}
    else
      config = Config.load_config()

      # Task.async_streamを使用してレート制限対策を実装
      activities =
        owners
        |> Task.async_stream(
          fn owner ->
            get_single_owner_activity(full_repo_name, owner)
          end,
          max_concurrency: min(config.api.max_concurrent, length(owners)),
          timeout: config.api.timeout_seconds * 1000,
          ordered: false,
          on_timeout: :kill_task
        )
        |> Enum.filter(fn
          {:ok, {:ok, _}} -> true
          _ -> false
        end)
        |> Enum.map(fn {:ok, {:ok, date}} -> date end)

      case activities do
        [] ->
          {:error, "No owner activity found"}

        dates ->
          # 最新のアクティビティを選択
          latest_date = get_latest_date(dates)
          {:ok, latest_date}
      end
    end
  end

  defp get_single_owner_activity(full_repo_name, owner) do
    with {:ok, commits} <-
           Client.get_repository_commits(full_repo_name, author: owner, per_page: 1),
         {:ok, latest_date} <- Parser.extract_latest_commit_date(commits) do
      {:ok, latest_date}
    else
      {:error, reason} ->
        Logger.debug("Failed to get activity for owner #{owner}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_latest_date(dates) do
    dates
    |> Enum.map(fn date_string ->
      case DateTime.from_iso8601(date_string) do
        {:ok, datetime, _} -> datetime
        _ -> nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
    |> Enum.max(DateTime)
    |> DateTime.to_iso8601()
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

  defp get_actual_developer_impl(repo_name, opts) do
    with {:ok, full_repo_name} <- build_full_repo_name(repo_name),
         {:ok, commits} <- Client.get_actual_developer(full_repo_name, opts),
         {:ok, developer} <-
           Parser.extract_actual_developer(commits, Config.load_config().github_org) do
      {:ok, developer}
    end
  end

  defp get_repository_pull_requests_impl(repo_name, opts) do
    with {:ok, full_repo_name} <- build_full_repo_name(repo_name),
         {:ok, pull_requests} <- Client.get_repository_pull_requests(full_repo_name, opts),
         {:ok, pr_status} <- Parser.extract_pr_status(pull_requests) do
      {:ok, pr_status}
    end
  end

  defp get_pull_request_reviews_impl(repo_name, pr_number, opts) do
    with {:ok, full_repo_name} <- build_full_repo_name(repo_name),
         {:ok, reviews} <- Client.get_pull_request_reviews(full_repo_name, pr_number, opts),
         {:ok, review_status} <- Parser.extract_review_status(reviews) do
      {:ok, review_status}
    end
  end

  defp get_pull_request_requested_reviewers_impl(repo_name, pr_number, opts) do
    with {:ok, full_repo_name} <- build_full_repo_name(repo_name),
         {:ok, response} <-
           Client.get_pull_request_requested_reviewers(full_repo_name, pr_number, opts) do
      {:ok, Parser.extract_requested_reviewers(response)}
    end
  end

  defp use_mock? do
    Parser.detect_environment_mode() == :test
  end
end
