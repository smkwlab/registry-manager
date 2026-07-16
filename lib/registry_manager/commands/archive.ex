defmodule RegistryManager.Commands.Archive do
  @moduledoc """
  卒業済み学生リポジトリの archive（卒業処理）。

  ## 使い方

      registry-manager archive <repo_name>            # 単発: open PR クローズ → archive → 記録
      registry-manager archive --graduated            # 名簿突合で卒業済みを一括実行
      registry-manager archive --graduated --list     # 候補一覧を判定理由つきで表示のみ
      registry-manager archive --graduated --dry-run  # 実行手順のシミュレーション（副作用なし）

  卒業判定は `RegistryManager.Archive.Classifier` に委譲する（registry × 名簿 ×
  現在の年度の結合）。「要確認」に分類された候補は一括実行から除外し、最後に一覧
  報告する（対話的な個別確認 `-i` は将来対応）。

  各リポジトリへの実行内容:

  1. open PR を整理コメント付きでクローズ（archive 後は read-only になるため先に行う）
  2. リポジトリを archive
  3. `archived_at`（ISO8601, UTC）を registry に記録

  registry の書き戻しは、成功した全リポジトリ分をまとめて 1 コミットで行う。
  個別リポジトリの失敗では中断せず、最後にまとめて報告する。

  ## 副作用のバイパス（テスト）

  `test_params`（キーワード）で外部依存を差し込める:

  - `:repositories` — registry マップ（`get_repositories_json` バイパス）
  - `:registry_sha` — 書き戻し用 sha（既定 `"test-sha"`）
  - `:roster` — 名簿エントリ list（`load_roster` バイパス）
  - `:current_nendo` — 判定基準年度
  - `:open_prs` — `%{repo => [%{number, title}]}`
  - `:mock_archive` — 実行結果をシミュレート（真値 = 成功 / `{:error, reason}` = 失敗）
  - `:now` — `archived_at` に使う ISO8601 文字列
  """

  alias RegistryManager.Archive.Classifier
  alias RegistryManager.GitHubAPI
  alias RegistryManager.Repository

  @close_comment "リポジトリの archive（卒業処理）に伴い、このプルリクエストをクローズします。"
  @commit_message "Archive graduated repositories (registry-manager)"

  @spec run(list(), keyword(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, opts, test_params \\ []) do
    normalized = validate_options(opts)

    case mode(args, normalized) do
      {:single, repo} -> run_single(repo, normalized, test_params)
      :graduated -> run_graduated(normalized, test_params)
      :error -> {:error, "archive <repo_name> または archive --graduated を指定してください"}
    end
  end

  @doc "オプションのデフォルト値を埋める"
  @spec validate_options(keyword()) :: keyword()
  def validate_options(opts) do
    [
      graduated: opts[:graduated] || false,
      list: opts[:list] || false,
      dry_run: opts[:dry_run] || false,
      verbose: opts[:verbose] || false
    ]
  end

  defp mode([repo], _opts), do: {:single, repo}
  defp mode([], opts), do: if(opts[:graduated], do: :graduated, else: :error)
  defp mode(_, _), do: :error

  # --- 一括（--graduated） -------------------------------------------------

  defp run_graduated(opts, test_params) do
    with {:ok, {registry, sha}} <- get_registry(test_params),
         {:ok, roster} <- get_roster(test_params) do
      nendo = test_params[:current_nendo] || Classifier.current_nendo()
      results = Classifier.classify_all(registry, roster, nendo)

      cond do
        opts[:list] -> {:ok, format_list(results, test_params)}
        opts[:dry_run] -> {:ok, format_dry_run(results, test_params)}
        true -> execute_graduated(results, registry, sha, test_params)
      end
    end
  end

  defp execute_graduated(results, registry, sha, test_params) do
    graduated = Enum.filter(results, &(&1.classification == :graduated))

    exec_results = Enum.map(graduated, fn r -> {r.repo, archive_one(r.repo, test_params)} end)
    archived_ok = for {repo, {:ok, _}} <- exec_results, do: repo

    new_registry = build_archived_registry(registry, archived_ok, now_iso(test_params))
    write_result = maybe_write(new_registry, archived_ok, sha)

    output = format_execute(exec_results, results, write_result)

    if execute_failed?(exec_results, write_result) do
      {:error, output}
    else
      {:ok, output}
    end
  end

  defp execute_failed?(exec_results, write_result) do
    Enum.any?(exec_results, fn {_repo, res} -> match?({:error, _}, res) end) or
      match?({:error, _}, write_result)
  end

  # --- 単発（archive <repo>） ----------------------------------------------

  defp run_single(repo, opts, test_params) do
    with {:ok, {registry, sha}} <- get_registry(test_params) do
      case Map.get(registry, repo) do
        nil ->
          {:error, "リポジトリ '#{repo}' は registry に登録されていません"}

        %{"archived_at" => archived_at} when is_binary(archived_at) ->
          {:ok, "#{repo} は既に archive 済みです（archived_at: #{archived_at}）"}

        _data ->
          archive_or_simulate_single(repo, registry, sha, opts, test_params)
      end
    end
  end

  # 単発でも --dry-run を尊重し、副作用なしでシミュレーション表示する
  defp archive_or_simulate_single(repo, registry, sha, opts, test_params) do
    if opts[:dry_run] do
      {:ok, format_single_dry_run(repo, test_params)}
    else
      archive_single(repo, registry, sha, test_params)
    end
  end

  defp format_single_dry_run(repo, test_params) do
    "[DRY-RUN] #{repo} — open PR #{open_pr_count_display(repo, test_params)} 件をクローズ → " <>
      "archive → archived_at 記録（副作用なし）"
  end

  defp archive_single(repo, registry, sha, test_params) do
    case archive_one(repo, test_params) do
      {:ok, %{closed_prs: n}} ->
        new_registry = build_archived_registry(registry, [repo], now_iso(test_params))

        case maybe_write(new_registry, [repo], sha) do
          :ok -> {:ok, "✅ #{repo}: archived（PR #{n} 件クローズ）"}
          {:error, reason} -> {:error, "#{repo} を archive しましたが registry 更新に失敗: #{reason}"}
        end

      {:error, reason} ->
        {:error, "❌ #{repo}: #{reason}"}
    end
  end

  # --- 実行（1 リポジトリ） -------------------------------------------------

  # test_params[:mock_archive] があれば実 API を叩かずシミュレート（propagate の
  # :mock_git と同型）。無ければ GitHubAPI 経由で実際に close/archive する。
  defp archive_one(repo, test_params) do
    case Keyword.fetch(test_params, :mock_archive) do
      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, _truthy} ->
        with {:ok, prs} <- get_open_prs(repo, test_params) do
          {:ok, %{closed_prs: length(prs)}}
        end

      :error ->
        do_archive(repo, test_params)
    end
  end

  # open PR 一覧の取得に失敗したら archive しない。取得できないまま archive すると
  # open PR を閉じ残したまま read-only 化してしまうため、失敗はそのまま伝播させる。
  defp do_archive(repo, test_params) do
    with {:ok, prs} <- get_open_prs(repo, test_params),
         :ok <- close_prs(repo, prs),
         {:ok, _} <- GitHubAPI.archive_repository(repo) do
      {:ok, %{closed_prs: length(prs)}}
    end
  end

  # archive 後は read-only になるため open PR を先にすべて閉じる。
  # 1 件でも失敗したらそのリポジトリは archive せず失敗として扱う。
  defp close_prs(repo, prs) do
    Enum.reduce_while(prs, :ok, fn pr, :ok ->
      case close_single_pr(repo, pr) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "PR ##{pr.number} クローズ失敗: #{reason}"}}
      end
    end)
  end

  defp close_single_pr(repo, pr) do
    with {:ok, _} <- GitHubAPI.create_issue_comment(repo, pr.number, @close_comment),
         {:ok, _} <- GitHubAPI.close_pull_request(repo, pr.number) do
      :ok
    end
  end

  # 戻り値は {:ok, [pr]} | {:error, reason}。取得失敗を握り潰さず呼び出し側に返す。
  defp get_open_prs(repo, test_params) do
    case test_params[:open_prs] do
      nil -> GitHubAPI.list_open_pull_requests(repo)
      map -> {:ok, Map.get(map, repo, [])}
    end
  end

  # 一覧・dry-run の表示用: 取得失敗時は件数を "?" とし、レビューは継続する
  defp open_pr_count_display(repo, test_params) do
    case get_open_prs(repo, test_params) do
      {:ok, prs} -> Integer.to_string(length(prs))
      {:error, _reason} -> "?"
    end
  end

  # --- registry 書き戻し ---------------------------------------------------

  @doc """
  指定リポジトリ群のエントリに `archived_at` を付与した registry を返す（純粋）。
  registry に存在しないリポジトリは無視する。
  """
  @spec build_archived_registry(map(), [String.t()], String.t()) :: map()
  def build_archived_registry(registry, repos, now_iso) do
    Enum.reduce(repos, registry, fn repo, acc ->
      case Map.get(acc, repo) do
        nil -> acc
        data -> Map.put(acc, repo, Map.put(data, "archived_at", now_iso))
      end
    end)
  end

  defp maybe_write(_registry, [], _sha), do: :no_change

  defp maybe_write(registry, _repos, sha) do
    case GitHubAPI.update_repositories_json(registry, sha, @commit_message) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp now_iso(test_params) do
    test_params[:now] || DateTime.to_iso8601(DateTime.utc_now())
  end

  defp get_registry(test_params) do
    if Keyword.has_key?(test_params, :repositories) do
      {:ok, {test_params[:repositories], Keyword.get(test_params, :registry_sha, "test-sha")}}
    else
      GitHubAPI.get_repositories_json()
    end
  end

  defp get_roster(test_params) do
    if Keyword.has_key?(test_params, :roster) do
      {:ok, test_params[:roster]}
    else
      Repository.load_roster()
    end
  end

  # --- 表示整形 ------------------------------------------------------------

  defp format_list(results, test_params) do
    header = "候補一覧（#{length(results)} 件）"
    lines = Enum.map(results, &format_list_line(&1, test_params))
    Enum.join([header | lines], "\n")
  end

  defp format_list_line(result, test_params) do
    pr =
      if result.classification == :graduated do
        open_pr_count_display(result.repo, test_params)
      else
        "-"
      end

    Enum.join(
      [
        label(result.classification),
        result.repo,
        "[#{result.repository_type}]",
        result.name || "-",
        "卒#{result.graduation_year || "-"}/修#{result.completion_year || "-"}",
        "PR:#{pr}",
        result.reason
      ],
      "\t"
    )
  end

  defp format_dry_run(results, test_params) do
    graduated = Enum.filter(results, &(&1.classification == :graduated))
    header = "[DRY-RUN] archive 対象: #{length(graduated)} 件（副作用なし）"

    lines =
      Enum.map(graduated, fn r ->
        "  #{r.repo} [#{r.repository_type}] #{r.name || "-"} — " <>
          "open PR #{open_pr_count_display(r.repo, test_params)} 件をクローズ → archive → archived_at 記録"
      end)

    Enum.join([header | lines], "\n")
  end

  defp format_execute(exec_results, all_results, write_result) do
    exec_lines = Enum.map(exec_results, &format_exec_line/1)
    review_lines = format_review_lines(all_results)
    (exec_lines ++ review_lines ++ ["", format_write_line(write_result)]) |> Enum.join("\n")
  end

  defp format_exec_line({repo, {:ok, %{closed_prs: n}}}), do: "✅ #{repo}: archived（PR #{n} 件クローズ）"
  defp format_exec_line({repo, {:error, reason}}), do: "❌ #{repo}: #{reason}"

  defp format_review_lines(all_results) do
    needs_review = Enum.filter(all_results, &(&1.classification == :needs_review))

    if needs_review == [] do
      []
    else
      ["", "要確認（スキップ・手動対応してください）:"] ++
        Enum.map(needs_review, fn r -> "  #{r.repo} — #{r.reason}" end)
    end
  end

  defp format_write_line(:ok), do: "registry を更新しました（archived_at 記録）"
  defp format_write_line(:no_change), do: "archive 対象がありませんでした"
  defp format_write_line({:error, reason}), do: "❌ registry 更新失敗: #{reason}"

  defp label(:graduated), do: "卒業済み"
  defp label(:enrolled), do: "在学中"
  defp label(:needs_review), do: "要確認"
  defp label(:already_archived), do: "archive済み"
end
