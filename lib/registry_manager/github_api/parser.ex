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
    # escript では Mix.env() が使えないため、環境変数とアプリケーション設定で判定する
    # (テストは test_helper.exs が :env を :test に設定する)
    env_var = System.get_env("MIX_ENV")
    app_env = Application.get_env(:registry_manager, :env)

    if env_var == "test" or app_env == :test do
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
end
