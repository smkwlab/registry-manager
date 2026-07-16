defmodule RegistryManager.GitHubAPI.Client do
  @moduledoc """
  GitHub API への実際のHTTPリクエスト処理
  外部依存（GitHub CLI認証 + Req）を担当

  このモジュールは外部依存のみを扱うため、テストカバレッジの対象外とする。
  実際のネットワーク通信とシステムコマンド実行を担当。
  """

  @doc """
  GitHub CLI を使用してアクセストークンを取得
  """
  def get_github_token do
    case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
      {token, 0} ->
        {:ok, String.trim(token)}

      {_output, _exit_code} ->
        {:error, "GitHub CLI authentication failed. Run 'gh auth login'"}
    end
  end

  @doc """
  GitHub API に HTTP リクエストを送信
  """
  def send_request(method, url, options \\ []) do
    headers = build_headers(options[:token])
    body = options[:body]

    request_opts = [
      method: method,
      url: url,
      headers: headers
    ]

    request_opts =
      if body do
        [json: body] ++ request_opts
      else
        request_opts
      end

    case Req.request(request_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        error_message = extract_error_message(response_body, status)
        {:error, "GitHub API error (#{status}): #{error_message}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
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
    url = "https://api.github.com/repos/#{repo}/contents/#{file_path}"

    with {:ok, token} <- get_github_token(),
         {:ok, response} <- send_request(:get, url, token: token) do
      {:ok, response}
    end
  end

  @doc """
  リポジトリのファイル内容を更新
  """
  def update_file_contents(repo, file_path, content, sha, commit_message) do
    url = "https://api.github.com/repos/#{repo}/contents/#{file_path}"

    body = %{
      message: commit_message,
      content: content,
      sha: sha
    }

    with {:ok, token} <- get_github_token(),
         {:ok, response} <- send_request(:put, url, token: token, body: body) do
      {:ok, response}
    end
  end

  @doc """
  リポジトリ情報を取得
  """
  def get_repository_info(repo_name) do
    url = "https://api.github.com/repos/#{repo_name}"

    with {:ok, token} <- get_github_token(),
         {:ok, response} <- send_request(:get, url, token: token) do
      {:ok, response}
    end
  end

  @doc """
  リポジトリのコミット履歴を取得
  """
  def get_repository_commits(repo_name, options \\ []) do
    author = options[:author]
    per_page = options[:per_page] || 1

    params =
      [per_page: per_page]
      |> maybe_add_author(author)
      |> URI.encode_query()

    url = "https://api.github.com/repos/#{repo_name}/commits?#{params}"

    with {:ok, token} <- get_github_token(),
         {:ok, response} <- send_request(:get, url, token: token) do
      {:ok, response}
    end
  end

  @doc """
  最近のコミット履歴から実際の開発者を特定
  組織所有のリポジトリで最も多くコミットしている人を見つける
  """
  def get_actual_developer(repo_name, options \\ []) do
    per_page = options[:per_page] || 10
    url = "https://api.github.com/repos/#{repo_name}/commits?per_page=#{per_page}"

    with {:ok, token} <- get_github_token(),
         {:ok, response} <- send_request(:get, url, token: token) do
      {:ok, response}
    end
  end

  @doc """
  リポジトリのプルリクエスト一覧を取得
  """
  def get_repository_pull_requests(repo_name, options \\ []) do
    state = options[:state] || "all"
    per_page = options[:per_page] || 100

    params = URI.encode_query(state: state, per_page: per_page)
    url = "https://api.github.com/repos/#{repo_name}/pulls?#{params}"

    with {:ok, token} <- get_github_token(),
         {:ok, response} <- send_request(:get, url, token: token) do
      {:ok, response}
    end
  end

  @doc """
  プルリクエストのレビュー一覧を取得
  """
  def get_pull_request_reviews(repo_name, pr_number, _options \\ []) do
    url = "https://api.github.com/repos/#{repo_name}/pulls/#{pr_number}/reviews"

    with {:ok, token} <- get_github_token(),
         {:ok, response} <- send_request(:get, url, token: token) do
      {:ok, response}
    end
  end

  @doc """
  プルリクエストの保留中のレビューリクエストを取得
  """
  def get_pull_request_requested_reviewers(repo_name, pr_number, _options \\ []) do
    url = "https://api.github.com/repos/#{repo_name}/pulls/#{pr_number}/requested_reviewers"

    with {:ok, token} <- get_github_token(),
         {:ok, response} <- send_request(:get, url, token: token) do
      {:ok, response}
    end
  end

  @doc """
  Issue / Pull Request にコメントを投稿（archive 前の整理コメント用）
  """
  def create_issue_comment(repo_name, issue_number, body) do
    url = "https://api.github.com/repos/#{repo_name}/issues/#{issue_number}/comments"

    with {:ok, token} <- get_github_token(),
         {:ok, response} <- send_request(:post, url, token: token, body: %{body: body}) do
      {:ok, response}
    end
  end

  @doc """
  Pull Request をクローズ（archive 後は read-only になるため事前に閉じる）
  """
  def close_pull_request(repo_name, pr_number) do
    url = "https://api.github.com/repos/#{repo_name}/pulls/#{pr_number}"

    with {:ok, token} <- get_github_token(),
         {:ok, response} <- send_request(:patch, url, token: token, body: %{state: "closed"}) do
      {:ok, response}
    end
  end

  @doc """
  リポジトリを archive する（卒業処理）
  """
  def archive_repository(repo_name) do
    url = "https://api.github.com/repos/#{repo_name}"

    with {:ok, token} <- get_github_token(),
         {:ok, response} <- send_request(:patch, url, token: token, body: %{archived: true}) do
      {:ok, response}
    end
  end

  # プライベート関数

  defp build_headers(token) do
    base_headers = [
      {"Accept", "application/vnd.github.v3+json"},
      {"User-Agent", "registry-manager/1.0"}
    ]

    if token do
      [{"Authorization", "Bearer #{token}"} | base_headers]
    else
      base_headers
    end
  end

  defp extract_error_message(%{"message" => message}, _status), do: message
  defp extract_error_message(body, status) when is_binary(body), do: "#{status} - #{body}"
  defp extract_error_message(_body, status), do: "HTTP #{status}"

  defp maybe_add_author(params, nil), do: params
  defp maybe_add_author(params, author), do: [author: author] ++ params
end
