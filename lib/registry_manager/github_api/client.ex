defmodule RegistryManager.GitHubAPI.Client do
  @moduledoc """
  GitHub API への HTTP 境界（ToolKit.GitHub.Client の薄いラッパ）

  HTTP 送信・トークン取得・エラー分類の機構は `ToolKit.GitHub.Client` に
  委譲し、本モジュールは registry-manager が使う endpoint と、従来の
  エラーメッセージ語彙（"GitHub API error (STATUS): ..." /
  "Request failed: ..."）への変換を担当する。

  このモジュールは外部依存のみを扱うため、テストカバレッジの対象外とする。
  実際のネットワーク通信とシステムコマンド実行を担当。
  """

  alias ToolKit.GitHub.Client, as: ToolKitClient

  @user_agent "registry-manager/1.0"
  @token_error_message "GitHub CLI authentication failed. Run 'gh auth login'"

  @doc """
  GitHub CLI を使用してアクセストークンを取得
  """
  def get_github_token do
    case ToolKitClient.gh_cli_token() do
      {:ok, token} -> {:ok, token}
      {:error, _reason} -> {:error, @token_error_message}
    end
  end

  @doc """
  GitHub API に HTTP リクエストを送信

  `url` は完全 URL。`options[:token]` のトークンを使い、`options[:body]`
  があれば JSON として送信する。
  """
  def send_request(method, url, options \\ []) do
    {base_url, path} = split_url(url)

    opts =
      [base_url: base_url, user_agent: @user_agent]
      |> Keyword.merge(auth_opts(options[:token]))
      |> put_json(options[:body])

    method
    |> ToolKitClient.request(path, opts)
    |> legacy_result()
  end

  @doc """
  send_request/3 が返したエラーメッセージが 404 (Not Found) かを判定

  エラーメッセージ形式（"GitHub API error (STATUS): ..."）は本モジュールが
  生成するため、形式を変更する場合はこの述語も併せて更新すること。
  """
  def not_found_error?(message) when is_binary(message),
    do: String.contains?(message, "GitHub API error (404)")

  def not_found_error?(_), do: false

  @doc """
  リポジトリのファイル内容を取得
  """
  def get_file_contents(repo, file_path) do
    repo
    |> ToolKitClient.get_file_contents(file_path, base_opts())
    |> legacy_result()
  end

  @doc """
  リポジトリのファイル内容を更新

  `content` は呼び出し側で base64 エンコード済み（Parser.encode_file_content）
  のため、生テキストを再エンコードする `ToolKit.GitHub.Client.put_file_contents/5`
  ではなく `put/3` をそのまま使う。
  """
  def update_file_contents(repo, file_path, content, sha, commit_message) do
    body = %{
      message: commit_message,
      content: content,
      sha: sha
    }

    "/repos/#{repo}/contents/#{file_path}"
    |> ToolKitClient.put(body, base_opts())
    |> legacy_result()
  end

  @doc """
  リポジトリ情報を取得
  """
  def get_repository_info(repo_name) do
    repo_name
    |> ToolKitClient.get_repository(base_opts())
    |> legacy_result()
  end

  @doc """
  リポジトリのコミット履歴を取得
  """
  def get_repository_commits(repo_name, options \\ []) do
    opts = [author: options[:author], per_page: options[:per_page] || 1] ++ base_opts()

    repo_name
    |> ToolKitClient.list_commits(opts)
    |> legacy_result()
  end

  @doc """
  最近のコミット履歴から実際の開発者を特定
  組織所有のリポジトリで最も多くコミットしている人を見つける
  """
  def get_actual_developer(repo_name, options \\ []) do
    opts = [per_page: options[:per_page] || 10] ++ base_opts()

    repo_name
    |> ToolKitClient.list_commits(opts)
    |> legacy_result()
  end

  @doc """
  リポジトリのプルリクエスト一覧を取得
  """
  def get_repository_pull_requests(repo_name, options \\ []) do
    opts =
      [state: options[:state] || "all", per_page: options[:per_page] || 100] ++ base_opts()

    repo_name
    |> ToolKitClient.list_pull_requests(opts)
    |> legacy_result()
  end

  @doc """
  プルリクエストのレビュー一覧を取得
  """
  def get_pull_request_reviews(repo_name, pr_number, _options \\ []) do
    repo_name
    |> ToolKitClient.list_pull_request_reviews(pr_number, base_opts())
    |> legacy_result()
  end

  @doc """
  プルリクエストの保留中のレビューリクエストを取得
  """
  def get_pull_request_requested_reviewers(repo_name, pr_number, _options \\ []) do
    repo_name
    |> ToolKitClient.get_requested_reviewers(pr_number, base_opts())
    |> legacy_result()
  end

  @doc """
  Issue / Pull Request にコメントを投稿（archive 前の整理コメント用）
  """
  def create_issue_comment(repo_name, issue_number, body) do
    repo_name
    |> ToolKitClient.create_issue_comment(issue_number, body, base_opts())
    |> legacy_result()
  end

  @doc """
  Pull Request をクローズ（archive 後は read-only になるため事前に閉じる）
  """
  def close_pull_request(repo_name, pr_number) do
    repo_name
    |> ToolKitClient.close_pull_request(pr_number, base_opts())
    |> legacy_result()
  end

  @doc """
  リポジトリを archive する（卒業処理）
  """
  def archive_repository(repo_name) do
    repo_name
    |> ToolKitClient.archive_repository(base_opts())
    |> legacy_result()
  end

  # プライベート関数

  # トークンは ToolKit の既定プロバイダ（gh auth token）で取得する
  defp base_opts, do: [user_agent: @user_agent]

  defp split_url(url) do
    uri = URI.parse(url)
    base_url = URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port})
    path = uri.path || "/"
    path = if uri.query, do: path <> "?" <> uri.query, else: path

    {base_url, path}
  end

  defp auth_opts(nil) do
    # 旧実装と同じく token なしは Authorization ヘッダを付けない。
    # ToolKit はトークン必須のため req_options でヘッダごと差し替える。
    # ToolKit v0.2.0 の run_request/4 は req_options を Keyword.merge で
    # 最後に適用するため、この :headers が token_provider 由来のヘッダを
    # 完全に置き換えることを確認済み
    [
      token_provider: fn -> {:ok, ""} end,
      req_options: [
        headers: [
          {"accept", "application/vnd.github+json"},
          {"user-agent", @user_agent}
        ]
      ]
    ]
  end

  defp auth_opts(token), do: [token_provider: fn -> {:ok, token} end]

  defp put_json(opts, nil), do: opts
  defp put_json(opts, body), do: Keyword.put(opts, :json, body)

  # ToolKit の分類済みエラーを従来のメッセージ語彙に写す
  defp legacy_result({:ok, body}), do: {:ok, body}

  defp legacy_result({:error, :not_found}),
    do: {:error, "GitHub API error (404): Not Found"}

  defp legacy_result({:error, :unauthorized}),
    do: {:error, "GitHub API error (401/403): authentication failed or insufficient permissions"}

  defp legacy_result({:error, {:http_error, status, message}}),
    do: {:error, "GitHub API error (#{status}): #{message}"}

  defp legacy_result({:error, {:request_failed, reason}}),
    do: {:error, "Request failed: #{inspect(reason)}"}

  defp legacy_result({:error, {:token_error, _reason}}),
    do: {:error, @token_error_message}
end
