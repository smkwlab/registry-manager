defmodule RegistryManager.GitHubAPI.Parser do
  @moduledoc """
  GitHub API レスポンスの変換・検証ロジック
  純粋関数のみでテスト可能

  このモジュールは外部依存を持たない純粋関数のみで構成され、
  テストカバレッジ向上の対象となる。
  """

  # Test safety check constants
  # Organization-specific test student IDs are supplied by callers via
  # Config.test_student_ids; only generic patterns are built in.
  @test_repo_patterns ["test-repo"]

  @doc """
  GitHub API から取得したファイル内容をデコード
  """
  def decode_file_response(%{"content" => content, "sha" => sha}) do
    with {:ok, decoded_content} <- decode_base64_content(content),
         {:ok, data} <- decode_json_content(decoded_content) do
      {:ok, {data, sha}}
    end
  end

  def decode_file_response(_response) do
    {:error, "Invalid file response format"}
  end

  @doc """
  データをGitHub API用にエンコード
  """
  def encode_file_content(data) do
    with {:ok, json_string} <- Jason.encode(data, pretty: true),
         encoded_content <- Base.encode64(json_string) do
      {:ok, encoded_content}
    else
      {:error, reason} -> {:error, "JSON encoding failed: #{inspect(reason)}"}
    end
  end

  @doc """
  リポジトリ活動情報を抽出
  """
  def extract_repository_activity(%{"pushed_at" => pushed_at}) when is_binary(pushed_at) do
    {:ok, pushed_at}
  end

  def extract_repository_activity(%{"updated_at" => updated_at}) when is_binary(updated_at) do
    # Fallback to updated_at if pushed_at is not available
    {:ok, updated_at}
  end

  def extract_repository_activity(_response) do
    {:error, "No activity timestamp found"}
  end

  @doc """
  コミット履歴から最新の活動時刻を抽出
  """
  def extract_latest_commit_date([%{"commit" => %{"author" => %{"date" => date}}} | _]) do
    {:ok, date}
  end

  def extract_latest_commit_date([]) do
    {:error, "No commits found"}
  end

  def extract_latest_commit_date(_commits) do
    {:error, "Unexpected commit response format"}
  end

  @doc """
  レジストリデータから学生のGitHubユーザー名を取得
  """
  def find_github_username_for_student(data, target_student_id) do
    case Enum.find(data, fn {_repo_name, repo_info} ->
           Map.get(repo_info, "student_id") == target_student_id
         end) do
      {_repo_name, repo_info} ->
        extract_github_username_from_repo_info(repo_info)

      nil ->
        {:error, "No repository found for student"}
    end
  end

  @doc """
  リポジトリ情報からGitHubユーザー名を抽出
  """
  def extract_github_username_from_repo_info(repo_info) do
    case Map.get(repo_info, "github_username") do
      nil -> {:error, "GitHub username not found in registry"}
      username when is_binary(username) and username != "" -> {:ok, username}
      _ -> {:error, "Invalid GitHub username format"}
    end
  end

  @doc """
  テストデータの安全性チェック

  `test_student_ids` には設定（Config.test_student_ids）で指定された
  組織固有のテスト用学生IDリストを渡す。

  注意: `test_student_ids` が空（デフォルト）の場合、学生ID による
  チェックは行われず、組み込みパターン（`test-repo` プレフィックス）
  のみで本番データを保護する。テスト用 ID を運用している組織は必ず
  設定すること。
  """
  def validate_test_safety(repo_name, production_mode \\ false, test_student_ids \\ []) do
    if production_mode and test_repository?(repo_name, test_student_ids) do
      {:error,
       "SAFETY ERROR: Attempting to modify test data '#{repo_name}' in production environment!"}
    else
      :ok
    end
  end

  @doc """
  Base64エンコードされたコンテンツをデコード
  """
  def decode_base64_content(content) do
    decoded = content |> String.replace("\n", "") |> Base.decode64!()
    {:ok, decoded}
  rescue
    _ -> {:error, "Base64 decode failed"}
  end

  @doc """
  JSON文字列をデコード
  """
  def decode_json_content(content) do
    case Jason.decode(content) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, "JSON decode failed"}
    end
  end

  @doc """
  環境モードの判定
  """
  def detect_environment_mode do
    # Check both System.get_env and Mix.env for comprehensive detection
    env_var = System.get_env("MIX_ENV")
    mix_env = if Code.ensure_loaded?(Mix), do: Mix.env() |> to_string(), else: nil

    if env_var == "test" or mix_env == "test" do
      :test
    else
      :production
    end
  end

  # プライベート関数

  defp test_repository?(repo_name, test_student_ids) do
    # Check for exact student ID prefix match (e.g., "k92rs123-anything")
    student_id_match =
      Enum.any?(test_student_ids, fn student_id ->
        String.starts_with?(repo_name, student_id <> "-")
      end)

    # Check for test repository patterns
    test_pattern_match =
      Enum.any?(@test_repo_patterns, fn pattern ->
        String.starts_with?(repo_name, pattern)
      end)

    student_id_match or test_pattern_match
  end

  @doc """
  リポジトリ所有者が組織かどうかを判定
  """
  def organization_owner?(owner_login) do
    # 一般的な組織アカウント名のパターンをチェック
    # 学生IDパターン（k##xxx###）ではない場合を組織とみなす
    not Regex.match?(~r/^k\d{2}[a-z]{2,3}\d{3}$/, owner_login)
  end

  @doc """
  コミット履歴から実際の開発者を特定
  GitHub Actionsによる自動コミットを除外し、学生による実際のコミットを優先

  `org` に組織アカウント名（Config.github_org）を渡すと、そのアカウントも
  自動化アカウントとして除外する。`nil`（デフォルト）または空文字列の場合、
  組織アカウントの除外は行わない。
  """
  def extract_actual_developer(commits_response, org \\ nil)

  def extract_actual_developer(commits_response, org) when is_list(commits_response) do
    commits_response
    |> Enum.map(&extract_commit_author_login/1)
    |> Enum.reject(&is_nil/1)
    |> filter_automation_accounts(org)
    |> case do
      [] ->
        {:error, "No valid commit authors found"}

      logins ->
        most_frequent =
          logins
          |> Enum.frequencies()
          |> Enum.max_by(fn {_login, count} -> count end)
          |> elem(0)

        {:ok, most_frequent}
    end
  end

  def extract_actual_developer(_, _org), do: {:error, "Invalid commits response format"}

  defp extract_commit_author_login(%{"author" => %{"login" => login}}) when is_binary(login),
    do: login

  defp extract_commit_author_login(_), do: nil

  @doc """
  自動化アカウントを除外してフィルタリング
  GitHub Actions、ボット、組織アカウント（org 指定時）を除外し、学生アカウントを優先

  `org` が `nil`（デフォルト）または空文字列の場合、組織アカウントの除外は
  行わず、組み込みの自動化アカウントパターンのみを除外する。
  """
  def filter_automation_accounts(logins, org \\ nil) do
    logins
    |> Enum.reject(&automation_account?(&1, org))
    |> case do
      # すべて自動化アカウントの場合は元のリストを返す
      [] -> logins
      filtered -> filtered
    end
  end

  defp automation_account?(login, org) do
    automation_patterns =
      [
        "actions-user",
        "github-actions",
        "dependabot",
        "renovate",
        # 組織アカウント（設定された場合のみ。空文字列は未設定扱い）
        org
      ]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))

    # 完全一致またはボットパターン
    Enum.any?(automation_patterns, fn pattern ->
      login == pattern or String.ends_with?(login, "[bot]")
    end)
  end

  @doc """
  プルリクエストデータからステータス情報を抽出

  Returns a map with:
  - `:total` - total number of PRs
  - `:open` - number of open PRs
  - `:closed` - number of closed PRs
  - `:merged` - number of merged PRs
  - `:draft` - number of draft PRs
  - `:status` - status string ("No PRs", "In Progress", "Complete", "Under Review")
  - `:updated_at` - ISO8601 timestamp of most recently updated PR (nil if no PRs)
  - `:created_at` - ISO8601 timestamp of most recently created PR (nil if no PRs)
  """
  def extract_pr_status(pull_requests) when is_list(pull_requests) do
    total = length(pull_requests)
    open = count_prs_by_state(pull_requests, "open")
    closed = count_prs_by_state(pull_requests, "closed")
    merged = count_merged_prs(pull_requests)
    draft = count_draft_prs(pull_requests)

    status = determine_pr_status(open, closed, merged, total)

    # Extract timestamps from PRs (most recent updated_at and created_at)
    {updated_at, created_at} = extract_pr_timestamps(pull_requests)

    pr_status = %{
      total: total,
      open: open,
      closed: closed,
      merged: merged,
      draft: draft,
      status: status,
      updated_at: updated_at,
      created_at: created_at
    }

    {:ok, pr_status}
  end

  def extract_pr_status(_), do: {:error, "Invalid pull requests response format"}

  @doc """
  レビューデータからレビュー状況を抽出
  """
  def extract_review_status(reviews) when is_list(reviews) do
    total_reviews = length(reviews)
    approved = count_reviews_by_state(reviews, "APPROVED")
    changes_requested = count_reviews_by_state(reviews, "CHANGES_REQUESTED")
    commented = count_reviews_by_state(reviews, "COMMENTED")

    review_status = %{
      total_reviews: total_reviews,
      approved: approved,
      changes_requested: changes_requested,
      commented: commented
    }

    {:ok, review_status}
  end

  def extract_review_status(_), do: {:error, "Invalid reviews response format"}

  @doc """
  requested_reviewers API レスポンスまたはPRオブジェクトからレビューリクエスト情報を抽出

  Supports two formats:
  - API response format: `%{"users" => [...], "teams" => [...]}`
  - PR object format: `%{"requested_reviewers" => [...], "requested_teams" => [...]}`

  Returns a map with `:users` (list of user logins) and `:teams` (list of team slugs).
  Returns `%{users: [], teams: []}` for invalid input.
  """
  # Format 1: requested_reviewers API response (%{"users" => ..., "teams" => ...})
  def extract_requested_reviewers(%{"users" => users, "teams" => teams})
      when is_list(users) and is_list(teams) do
    extract_reviewers_from_lists(users, teams)
  end

  # Format 2: PR object format (%{"requested_reviewers" => ..., "requested_teams" => ...})
  # Issue #118: Support extracting from PR list response to reduce API calls
  def extract_requested_reviewers(%{
        "requested_reviewers" => reviewers,
        "requested_teams" => teams
      })
      when is_list(reviewers) and is_list(teams) do
    extract_reviewers_from_lists(reviewers, teams)
  end

  def extract_requested_reviewers(_), do: %{users: [], teams: []}

  defp extract_reviewers_from_lists(users, teams) do
    user_logins = Enum.map(users, fn user -> Map.get(user, "login") end) |> Enum.reject(&is_nil/1)
    team_slugs = Enum.map(teams, fn team -> Map.get(team, "slug") end) |> Enum.reject(&is_nil/1)

    %{
      users: user_logins,
      teams: team_slugs
    }
  end

  @doc """
  指定されたユーザーが保留中のレビューリクエストに含まれているか判定

  Returns `true` if the username is found in the requested reviewers list (case-insensitive),
  `false` otherwise or for invalid inputs.
  """
  def user_has_pending_review_request?(requested_reviewers, username)
      when is_map(requested_reviewers) and is_binary(username) do
    requested_reviewers
    |> Map.get(:users, [])
    |> Enum.any?(fn login -> String.downcase(login) == String.downcase(username) end)
  end

  def user_has_pending_review_request?(_, _), do: false

  @doc """
  PR オブジェクトが指定ユーザーのレビュー待ちか判定

  GitHub はレビュー提出時にユーザーを `requested_reviewers` から外し、
  レビュー再リクエストで戻すため、`requested_reviewers` への所属が
  そのまま「いまレビュー待ちか」を表す（過去のレビュー提出履歴は見ない）。

  Returns `true` if the username is currently in the PR's requested
  reviewers (case-insensitive), `false` otherwise or for invalid inputs.
  """
  def pr_awaiting_review_from?(pr, username) when is_map(pr) and is_binary(username) do
    pr
    |> extract_requested_reviewers()
    |> user_has_pending_review_request?(username)
  end

  def pr_awaiting_review_from?(_, _), do: false

  # プライベート関数

  defp count_prs_by_state(pull_requests, state) do
    Enum.count(pull_requests, fn pr ->
      Map.get(pr, "state") == state
    end)
  end

  defp count_merged_prs(pull_requests) do
    Enum.count(pull_requests, fn pr ->
      not is_nil(Map.get(pr, "merged_at"))
    end)
  end

  defp count_draft_prs(pull_requests) do
    Enum.count(pull_requests, fn pr ->
      Map.get(pr, "draft", false) == true
    end)
  end

  defp count_reviews_by_state(reviews, state) do
    Enum.count(reviews, fn review ->
      Map.get(review, "state") == state
    end)
  end

  # PRリストから最新のupdated_atとcreated_atを抽出
  # Note: Both timestamps use max (most recent) for sorting purposes.
  # - updated_at: Sort by most recently UPDATED PR (standard activity sorting)
  # - created_at: Sort by most recently CREATED PR (find repos with new PRs)
  # This surfaces recently active repositories, not the "first ever PR" in a repo.
  defp extract_pr_timestamps([]), do: {nil, nil}

  defp extract_pr_timestamps(pull_requests) do
    updated_at = find_most_recent_timestamp(pull_requests, "updated_at")
    created_at = find_most_recent_timestamp(pull_requests, "created_at")
    {updated_at, created_at}
  end

  defp find_most_recent_timestamp(pull_requests, field) do
    pull_requests
    |> Enum.map(fn pr -> Map.get(pr, field) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(& &1, fn -> nil end)
  end

  # PR進捗ベースのステータス判定
  # "In Progress" - オープンなPRが存在
  # "Under Review" - レビュー待ちのPRが存在
  # "Complete" - すべてのPRがマージ済み
  # "No PRs" - PRが1つも作成されていない
  defp determine_pr_status(open, _closed, merged, total) do
    cond do
      total == 0 -> "No PRs"
      open > 0 -> "In Progress"
      merged == total -> "Complete"
      true -> "Under Review"
    end
  end
end
