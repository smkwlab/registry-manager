defmodule RegistryManager.Commands.Archive do
  @moduledoc """
  卒業済み学生リポジトリの archive（卒業処理）。

  ## 使い方

      registry-manager archive <repo_name>            # 単発: open PR クローズ → archive → 記録
      registry-manager archive --graduated            # 名簿突合で卒業済みを一括実行
      registry-manager archive --graduated --list     # 候補一覧を判定理由つきで表示のみ
      registry-manager archive --graduated --dry-run  # 実行手順のシミュレーション（副作用なし）
      registry-manager archive --graduated -i         # 候補を 1 件ずつ確認しながら実行

  卒業判定は `RegistryManager.Archive.Classifier` に委譲する（registry × 名簿 ×
  現在の年度の結合）。非対話の一括実行では「要確認」に分類された候補を実行対象から
  除外し、最後に一覧報告する。対話実行（`-i`）では「卒業済み」に加えて「要確認」も
  1 件ずつ提示し、その場で人間が個別に判断できるようにする。

  各リポジトリへの実行内容:

  1. open PR を整理コメント付きでクローズ（archive 後は read-only になるため先に行う）
  2. リポジトリを archive
  3. `archived_at`（ISO8601, UTC）を registry に記録

  registry の書き戻しは、成功した全リポジトリ分をまとめて 1 コミットで行う。
  個別リポジトリの失敗では中断せず、最後にまとめて報告する。

  ## API 呼び出し（読み取り）

  `--list` / `--dry-run` は副作用（PR クローズ・archive・registry 書き戻し）は
  行わないが、表示のために「卒業済み」候補ごとに open PR 数を取得する読み取り
  専用 API 呼び出しを行う（候補件数に比例）。取得に失敗した場合は件数を `?` と
  表示して一覧・シミュレーションは継続する。

  ## 副作用のバイパス（テスト）

  `test_params`（キーワード）で外部依存を差し込める:

  - `:repositories` — registry マップ（`get_repositories_json` バイパス）
  - `:registry_sha` — 書き戻し用 sha（既定 `"test-sha"`）
  - `:roster` — 名簿エントリ list（`load_roster` バイパス）
  - `:current_nendo` — 判定基準年度
  - `:open_prs` — `%{repo => [%{number, title}]}`（PR 一覧の注入）
  - `:mock_archive` — archive 実行結果をシミュレート（真値 = 成功 / `{:error, reason}`
    = 失敗）。成功時は実際の close/archive は呼ばず、クローズ件数は `:open_prs` から
    数える（未注入なら `list_open_pull_requests` のモック既定で 0 件）。実 API を
    一切叩かせたくないテストでは `:open_prs` も併せて注入する
  - `:now` — `archived_at` に使う ISO8601 文字列
  - `:inputs` — 対話実行（`-i`）の応答列（`["y", "n", ...]`）。注入時は実 stdin を
    読まずこの列を順に消費する。列が尽きたら中断（`q`）として扱う
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
      interactive: opts[:interactive] || false,
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
        opts[:interactive] -> execute_interactive(results, registry, sha, test_params)
        true -> execute_graduated(results, registry, sha, test_params)
      end
    end
  end

  defp execute_graduated(results, registry, sha, test_params) do
    graduated = Enum.filter(results, &(&1.classification == :graduated))

    exec_results = Enum.map(graduated, fn r -> {r.repo, archive_one(r.repo, test_params)} end)
    archived_ok = for {repo, {:ok, _}} <- exec_results, do: repo

    new_registry = build_archived_registry(registry, archived_ok, now_iso(test_params))

    # 成功分が 1 件でもあれば 1 コミットでまとめて書き戻す。0 件なら書かない。
    write_result =
      if archived_ok == [] do
        :no_change
      else
        write_registry(new_registry, sha)
      end

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

  # --- 対話（--graduated -i） ----------------------------------------------

  @valid_answers ~w(y n a q)

  # 対話候補は「卒業済み」+「要確認」。非対話の一括実行は「要確認」を対象にしないが、
  # 対話ではその場で人間が個別に判断できるよう提示する（在学中・archive済みは除外）。
  defp execute_interactive(results, registry, sha, test_params) do
    candidates =
      results
      |> Enum.filter(&(&1.classification in [:graduated, :needs_review]))
      |> Enum.sort_by(&{candidate_order(&1.classification), &1.repo})

    {exec_results, transcript} = interactive_loop(candidates, test_params)
    archived_ok = for {repo, {:ok, _}} <- exec_results, do: repo

    new_registry = build_archived_registry(registry, archived_ok, now_iso(test_params))

    # 一括実行と同じく、成功分が 1 件でもあれば 1 コミットでまとめて書き戻す。
    write_result =
      if archived_ok == [] do
        :no_change
      else
        write_registry(new_registry, sha)
      end

    output = format_interactive(transcript, exec_results, write_result)

    if execute_failed?(exec_results, write_result) do
      {:error, output}
    else
      {:ok, output}
    end
  end

  # 対話の提示順: 判定が明確な「卒業済み」を先に、要確認を後に（同一分類内は repo 名順）
  defp candidate_order(:graduated), do: 0
  defp candidate_order(:needs_review), do: 1

  # candidates を 1 件ずつ確認しながら畳み込む。
  # 状態: auto?（a 選択後は確認なし）/ quit?（q 選択後は以降スキップ）/ 残り入力 /
  #       実行結果（{repo, result}）/ 表示ログ。
  defp interactive_loop(candidates, test_params) do
    initial = %{auto: false, quit: false, inputs: test_params[:inputs], exec: [], transcript: []}
    final = Enum.reduce(candidates, initial, &interactive_step(&1, &2, test_params))
    {Enum.reverse(final.exec), Enum.reverse(final.transcript)}
  end

  # quit と auto は同時に true にならない（q を選ぶと以降 prompt しないため auto に
  # 遷移しない）。仮に両方 true でも quit を優先する（残りは実行せずスキップ）。
  #
  # 中断後は残り候補をスキップとして記録するのみ
  defp interactive_step(cand, %{quit: true} = state, _test_params) do
    %{state | transcript: ["⏭  #{cand.repo}: 中断のためスキップ" | state.transcript]}
  end

  # a 選択後は確認せず archive
  defp interactive_step(cand, %{auto: true} = state, test_params) do
    apply_archive(cand, state, test_params)
  end

  defp interactive_step(cand, state, test_params) do
    {answer, rest} = prompt_answer(cand, state.inputs, test_params)
    state = %{state | inputs: rest}

    # prompt_answer は @valid_answers（y/n/a/q）のいずれかのみを返すため、この case は
    # それを網羅する。無言フォールバック（_ -> state）はスキップと区別できず将来の
    # 不整合を隠すため置かず、@valid_answers を増やす際はこの case も更新する。
    case answer do
      "y" -> apply_archive(cand, state, test_params)
      "a" -> apply_archive(cand, %{state | auto: true}, test_params)
      "n" -> %{state | transcript: ["⏭  #{cand.repo}: スキップ" | state.transcript]}
      "q" -> %{state | quit: true, transcript: ["🛑 中断しました" | state.transcript]}
    end
  end

  defp apply_archive(cand, state, test_params) do
    result = archive_one(cand.repo, test_params)

    %{
      state
      | exec: [{cand.repo, result} | state.exec],
        transcript: [format_exec_line({cand.repo, result}) | state.transcript]
    }
  end

  # 有効な応答（y/n/a/q）が得られるまで読み取る。入力終端（eof / 注入列の枯渇）は
  # 中断（q）として扱う。無効な入力は本番でのみ注意表示して再入力を促す。
  # 無効入力時の再帰は末尾位置（TCO 対象）なのでスタックは伸びない。
  defp prompt_answer(cand, inputs, test_params) do
    {raw, rest} = read_line(prompt_text(cand, test_params), inputs)

    case normalize_answer(raw) do
      :eof ->
        {"q", rest}

      answer when answer in @valid_answers ->
        {answer, rest}

      _invalid ->
        notify_invalid(test_params)
        prompt_answer(cand, rest, test_params)
    end
  end

  # inputs が nil のときだけ実 stdin を読む（本番）。list のときは注入応答を消費する。
  defp read_line(prompt, nil) do
    case IO.gets(prompt) do
      :eof -> {:eof, nil}
      {:error, _reason} -> {:eof, nil}
      line -> {line, nil}
    end
  end

  defp read_line(_prompt, []), do: {:eof, []}
  defp read_line(_prompt, [head | tail]), do: {head, tail}

  defp normalize_answer(:eof), do: :eof
  defp normalize_answer(raw) when is_binary(raw), do: raw |> String.trim() |> String.downcase()

  # 本番（実 stdin）でのみ無効入力を通知する。応答注入（test_params[:inputs]）が
  # あるテストでは静かに再入力する。判定は再帰で不変な test_params に基づく。
  defp notify_invalid(test_params) do
    if Keyword.has_key?(test_params, :inputs) do
      :ok
    else
      IO.puts("y / n / a / q のいずれかで答えてください。")
    end
  end

  defp prompt_text(cand, test_params) do
    pr =
      if cand.classification == :graduated do
        open_pr_count_display(cand.repo, test_params)
      else
        "-"
      end

    header =
      Enum.join(
        [
          label(cand.classification),
          cand.repo,
          "[#{cand.repository_type}]",
          cand.name || "-",
          "卒#{cand.graduation_year || "-"}/修#{cand.completion_year || "-"}",
          "PR:#{pr}",
          cand.reason
        ],
        "\t"
      )

    "#{header}\n  archive しますか? [y=実行 / n=スキップ / a=以降すべて / q=中断]: "
  end

  defp format_interactive(transcript, exec_results, write_result) do
    executed = Enum.count(exec_results, fn {_repo, res} -> match?({:ok, _}, res) end)
    header = "対話 archive 完了（#{executed} 件を archive）"

    # transcript は interactive_loop で Enum.reverse 済み＝提示順（先頭が最初の候補）
    lines = [header] ++ transcript ++ ["", format_write_line(write_result)]
    Enum.join(lines, "\n")
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

        # 単発は必ず 1 件書き戻すので :no_change は発生しない（write_registry は :ok | {:error}）
        case write_registry(new_registry, sha) do
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

  # 常に registry を書き戻す（呼び出し側で「書き戻す対象があるか」を判定する）。
  # 戻り値は :ok | {:error, reason} のみで、両呼び出し側の match は網羅的。
  defp write_registry(registry, sha) do
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
