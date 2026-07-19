defmodule RegistryManager.Commands.PrStatus do
  @moduledoc """
  Pull Request status command implementation.

  Shows comprehensive PR information including:
  - Open/closed PR counts
  - Review status
  - Merge status
  - PR activity timeline

  ## Caching (Issue #120)

  PR status data is cached to reduce GitHub API calls:
  - Default TTL: 5 minutes
  - Cache location: `~/.cache/registry-manager/pr-status/`
  - Use `--no-cache` to bypass cache
  """

  alias RegistryManager.Cache
  alias RegistryManager.CLI.Spec
  alias RegistryManager.GitHubAPI
  alias RegistryManager.GitHubAPI.{Client, Parser}

  # Issue #120: Cache configuration
  @cache_category "pr-status"
  @default_cache_ttl_minutes 5

  @spec run(list(), keyword(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(_args, opts, test_params \\ []) do
    with {:ok, validated_opts} <- validate_options(opts),
         {:ok, repositories} <- get_repositories(test_params),
         {:ok, filtered_repos} <- filter_repositories(repositories, validated_opts),
         {:ok, pr_data} <- fetch_pr_data(filtered_repos, validated_opts, test_params),
         {:ok, filtered_pr_data} <- filter_pr_data_by_state(pr_data, validated_opts),
         {:ok, review_filtered_data} <-
           filter_by_review_requested(filtered_pr_data, validated_opts, test_params),
         {:ok, sorted_data} <- sort_pr_data(review_filtered_data, validated_opts),
         {:ok, output} <- format_output(sorted_data, validated_opts) do
      {:ok, output}
    end
  end

  @doc """
  オプション検証
  """
  def validate_options(opts) do
    with {:ok, format} <- validate_format(opts[:format] || "table"),
         {:ok, type} <- validate_type(opts[:type]),
         {:ok, state} <- validate_state(opts[:state] || "all"),
         {:ok, sort} <- validate_sort(opts[:sort]) do
      {:ok, build_validated_opts(opts, format, type, state, sort)}
    end
  end

  defp build_validated_opts(opts, format, type, state, sort) do
    effective_sort = determine_effective_sort(sort, opts[:review_requested])

    [
      format: format,
      type: type,
      state: state,
      no_cache: opts[:no_cache] || false,
      sort: effective_sort,
      reverse: opts[:reverse] || false,
      review_requested: opts[:review_requested] || false
    ]
  end

  # review_requested 指定時はデフォルトで updated 順にソート
  defp determine_effective_sort(nil, true), do: "updated"
  defp determine_effective_sort(nil, _), do: "repository"
  defp determine_effective_sort(sort, _), do: sort

  # プライベート関数

  defp validate_format(format) do
    if format in Spec.output_formats() do
      {:ok, format}
    else
      {:error,
       "Invalid format: #{format}. Valid formats: #{Enum.join(Spec.output_formats(), ", ")}"}
    end
  end

  defp validate_type(nil), do: {:ok, nil}

  defp validate_type(type) do
    if type in Spec.repo_types() do
      {:ok, type}
    else
      {:error, "Invalid type: #{type}. Valid types: #{Enum.join(Spec.repo_types(), ", ")}"}
    end
  end

  defp validate_state(state) do
    if state in Spec.pr_states() do
      {:ok, state}
    else
      {:error, "Invalid state: #{state}. Valid states: #{Enum.join(Spec.pr_states(), ", ")}"}
    end
  end

  defp validate_sort(nil), do: {:ok, nil}

  defp validate_sort(sort) do
    if sort in Spec.pr_sort_keys() do
      {:ok, sort}
    else
      {:error, "Invalid sort: #{sort}. Valid options: #{Enum.join(Spec.pr_sort_keys(), ", ")}"}
    end
  end

  defp get_repositories(test_params) do
    if Keyword.has_key?(test_params, :repositories) do
      {:ok, test_params[:repositories]}
    else
      case GitHubAPI.get_repositories_json() do
        {:ok, {repos, _sha}} -> {:ok, repos}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp filter_repositories(repositories, opts) do
    filtered =
      repositories
      |> filter_by_type(opts[:type])

    {:ok, filtered}
  end

  defp filter_by_type(repositories, nil), do: repositories

  # Issue #111: thesis shows both sotsuron and master repositories
  defp filter_by_type(repositories, "thesis") do
    Enum.filter(repositories, fn {_repo_name, repo_data} ->
      repo_type = Map.get(repo_data, "repository_type")
      repo_type == "sotsuron" or repo_type == "master"
    end)
    |> Enum.into(%{})
  end

  # Issue #111: other shows only repositories explicitly typed as "other"
  defp filter_by_type(repositories, "other") do
    Enum.filter(repositories, fn {_repo_name, repo_data} ->
      Map.get(repo_data, "repository_type") == "other"
    end)
    |> Enum.into(%{})
  end

  # Standard exact match for other types (wr, ise, sotsuron, master)
  defp filter_by_type(repositories, type) do
    Enum.filter(repositories, fn {_repo_name, repo_data} ->
      Map.get(repo_data, "repository_type") == type
    end)
    |> Enum.into(%{})
  end

  defp fetch_pr_data(repositories, opts, test_params) do
    cond do
      Keyword.has_key?(test_params, :api_error) ->
        {:error, test_params[:api_error]}

      Keyword.has_key?(test_params, :pr_data) ->
        # テストモード：pr_dataが指定されている場合はそれを使用し、キャッシュに保存
        pr_data = build_test_pr_data(repositories, test_params[:pr_data])
        save_pr_data_to_cache(pr_data, opts, test_params)
        {:ok, pr_data}

      true ->
        # 実際のAPIコール or キャッシュ使用
        fetch_pr_data_with_cache(repositories, opts, test_params)
    end
  end

  defp build_test_pr_data(repositories, pr_data) do
    repositories
    |> Enum.map(fn {repo_name, _repo_data} ->
      default = %{total: 0, open: 0, closed: 0, merged: 0, draft: 0, status: "No PRs"}
      {repo_name, Map.get(pr_data, repo_name, default)}
    end)
    |> Enum.into(%{})
  end

  # Issue #120: キャッシュを利用したPRデータ取得
  # 本番環境でもキャッシュを使用してAPIコールを削減
  defp fetch_pr_data_with_cache(repositories, opts, test_params) do
    require Logger

    no_cache = opts[:no_cache] || false

    pr_data =
      repositories
      |> Enum.map(fn {repo_name, _repo_data} ->
        fetch_repo_pr_data(repo_name, no_cache, opts, test_params)
      end)
      |> Enum.into(%{})

    {:ok, pr_data}
  end

  # --no-cache オプション指定時はキャッシュをバイパス
  defp fetch_repo_pr_data(repo_name, true, opts, _test_params) do
    fetch_single_repo_pr_data(repo_name, opts)
  end

  # デフォルト：キャッシュを確認し、なければAPIからフェッチ
  defp fetch_repo_pr_data(repo_name, false, opts, test_params) do
    case try_get_cached_pr_data(repo_name, test_params) do
      {:ok, cached_data} ->
        {repo_name, cached_data}

      {:error, _} ->
        # キャッシュミス - APIからフェッチ
        result = fetch_single_repo_pr_data(repo_name, opts)
        # キャッシュに保存
        {_, pr_status} = result
        save_single_repo_to_cache(repo_name, pr_status, opts, test_params)
        result
    end
  end

  defp fetch_single_repo_pr_data(repo_name, opts) do
    require Logger

    case GitHubAPI.get_repository_pull_requests(repo_name, state: opts[:state]) do
      {:ok, pr_status} ->
        {repo_name, pr_status}

      {:error, reason} ->
        Logger.warning("Failed to fetch PR data for #{repo_name}: #{inspect(reason)}")
        {repo_name, %{total: 0, open: 0, closed: 0, merged: 0, draft: 0, status: "Error"}}
    end
  end

  defp try_get_cached_pr_data(repo_name, test_params) do
    cache_dir = Keyword.get(test_params, :cache_dir)
    cache_opts = build_cache_opts(cache_dir)

    case Cache.get(repo_name, cache_opts) do
      {:ok, data} ->
        # キャッシュデータをアトムキーのマップに変換
        {:ok, convert_cached_data_to_atoms(data)}

      error ->
        error
    end
  end

  defp convert_cached_data_to_atoms(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} ->
      key = if is_binary(k), do: String.to_existing_atom(k), else: k
      {key, v}
    end)
    |> Enum.into(%{})
  rescue
    # String.to_existing_atom/1 が失敗した場合のみキャッチ
    ArgumentError -> data
  end

  defp save_pr_data_to_cache(pr_data, opts, test_params) do
    # no_cache 指定時はキャッシュに保存しない
    unless opts[:no_cache] do
      Enum.each(pr_data, fn {repo_name, pr_status} ->
        save_single_repo_to_cache(repo_name, pr_status, opts, test_params)
      end)
    end
  end

  defp save_single_repo_to_cache(repo_name, pr_status, _opts, test_params) do
    cache_dir = Keyword.get(test_params, :cache_dir)
    ttl_minutes = Keyword.get(test_params, :cache_ttl_minutes, @default_cache_ttl_minutes)

    cache_opts =
      build_cache_opts(cache_dir)
      |> Keyword.put(:ttl_minutes, ttl_minutes)

    # キャッシュに保存（文字列キーに変換）
    cache_data = convert_to_string_keys(pr_status)
    Cache.put(repo_name, cache_data, cache_opts)
  end

  defp convert_to_string_keys(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      {key, v}
    end)
    |> Enum.into(%{})
  end

  defp build_cache_opts(nil), do: [category: @cache_category]
  defp build_cache_opts(cache_dir), do: [category: @cache_category, cache_dir: cache_dir]

  defp filter_pr_data_by_state(pr_data, opts) do
    case opts[:state] do
      "all" ->
        {:ok, pr_data}

      "open" ->
        filtered =
          Enum.filter(pr_data, fn {_repo_name, pr_status} ->
            open = Map.get(pr_status, :open, 0)
            open > 0
          end)
          |> Enum.into(%{})

        {:ok, filtered}

      "closed" ->
        filtered =
          Enum.filter(pr_data, fn {_repo_name, pr_status} ->
            open = Map.get(pr_status, :open, 0)
            closed = Map.get(pr_status, :closed, 0)
            merged = Map.get(pr_status, :merged, 0)
            closed + merged > 0 and open == 0
          end)
          |> Enum.into(%{})

        {:ok, filtered}
    end
  end

  # Issue #115: --review-requested オプションによるフィルタリング
  defp filter_by_review_requested(pr_data, opts, test_params) do
    if opts[:review_requested] do
      filter_by_review_requested_impl(pr_data, test_params)
    else
      {:ok, pr_data}
    end
  end

  defp filter_by_review_requested_impl(pr_data, test_params) do
    require Logger

    # 現在のユーザー名を取得
    current_user =
      if Keyword.has_key?(test_params, :current_user) do
        test_params[:current_user]
      else
        get_current_github_user()
      end

    case current_user do
      nil ->
        Logger.warning("Could not determine current GitHub user")
        {:ok, pr_data}

      username ->
        filtered = filter_repos_by_pending_review(pr_data, username, test_params)
        {:ok, filtered}
    end
  end

  defp get_current_github_user do
    require Logger

    case Client.get_github_token() do
      {:ok, token} ->
        case Client.send_request(:get, "https://api.github.com/user", token: token) do
          {:ok, %{"login" => login}} ->
            login

          {:error, reason} ->
            # Issue #118: エラー発生時のログ出力を追加
            Logger.warning("Failed to get current GitHub user: #{inspect(reason)}")
            nil

          _ ->
            Logger.warning("Unexpected response from GitHub user API")
            nil
        end

      {:error, reason} ->
        # Issue #118: トークン取得エラー時のログ出力を追加
        Logger.warning("Failed to get GitHub token: #{inspect(reason)}")
        nil
    end
  end

  defp filter_repos_by_pending_review(pr_data, username, test_params) do
    pr_data
    |> Enum.filter(fn {repo_name, pr_status} ->
      has_pending_review_for_user?(repo_name, pr_status, username, test_params)
    end)
    |> Enum.into(%{})
  end

  defp has_pending_review_for_user?(repo_name, pr_status, username, test_params) do
    # テストモード
    if Keyword.has_key?(test_params, :pending_reviews) do
      pending_reviews = test_params[:pending_reviews]
      Map.get(pending_reviews, repo_name, false)
    else
      # 実際のAPIコール
      check_pending_review_from_api(repo_name, pr_status, username)
    end
  end

  defp check_pending_review_from_api(repo_name, pr_status, username) do
    require Logger

    # オープンなPRがない場合はスキップ
    if Map.get(pr_status, :open, 0) == 0 do
      false
    else
      # 各オープンPRをチェック
      case get_open_prs_with_pending_review(repo_name, username) do
        {:ok, has_pending} -> has_pending
        {:error, _} -> false
      end
    end
  end

  defp get_open_prs_with_pending_review(repo_name, username) do
    require Logger
    alias RegistryManager.Config

    config = Config.load_config()
    full_repo_name = "#{config.github_org}/#{repo_name}"

    # オープンなPR一覧を取得
    case Client.get_repository_pull_requests(full_repo_name, state: "open") do
      {:ok, prs} when is_list(prs) ->
        # requested_reviewers への所属がそのまま「いまレビュー待ちか」を表す
        # （GitHub はレビュー提出でユーザーを外し、再リクエストで戻すため、
        # 過去のレビュー提出履歴を別途確認すると再リクエストされた PR を
        # 誤って除外してしまう。Issue #58）
        has_pending = Enum.any?(prs, &Parser.pr_awaiting_review_from?(&1, username))

        {:ok, has_pending}

      {:error, reason} ->
        Logger.debug("Failed to get PRs for #{repo_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Issue #115: ソート機能
  # ソート済みリストを返す（Mapではなくリストで順序を維持）
  defp sort_pr_data(pr_data, opts) do
    sorted =
      case opts[:sort] do
        "repository" ->
          pr_data |> Enum.sort_by(&elem(&1, 0))

        "updated" ->
          pr_data |> Enum.sort_by(&get_updated_at(&1), {:desc, DateTime})

        "created" ->
          pr_data |> Enum.sort_by(&get_created_at(&1), {:desc, DateTime})

        _ ->
          pr_data |> Enum.sort_by(&elem(&1, 0))
      end

    sorted =
      if opts[:reverse] do
        Enum.reverse(sorted)
      else
        sorted
      end

    # リストとして返し、順序を維持
    {:ok, sorted}
  end

  defp get_updated_at({_repo_name, pr_status}) do
    case Map.get(pr_status, :updated_at) do
      nil -> ~U[1970-01-01 00:00:00Z]
      date_string when is_binary(date_string) -> parse_datetime(date_string)
      _ -> ~U[1970-01-01 00:00:00Z]
    end
  end

  defp get_created_at({_repo_name, pr_status}) do
    case Map.get(pr_status, :created_at) do
      nil -> ~U[1970-01-01 00:00:00Z]
      date_string when is_binary(date_string) -> parse_datetime(date_string)
      _ -> ~U[1970-01-01 00:00:00Z]
    end
  end

  defp parse_datetime(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _} -> datetime
      _ -> ~U[1970-01-01 00:00:00Z]
    end
  end

  defp format_output(pr_data, opts) do
    case opts[:format] do
      "table" -> format_table_output(pr_data, opts)
      "csv" -> format_csv_output(pr_data, opts)
      "json" -> format_json_output(pr_data, opts)
    end
  end

  defp format_table_output(pr_data, _opts) do
    if Enum.empty?(pr_data) do
      {:ok, "No repositories found."}
    else
      header = "Repository              | Total PRs | Open | Closed | Merged | Draft | Status"
      separator = String.duplicate("-", String.length(header))

      # pr_dataは既にソート済みリストなのでそのまま使用
      rows =
        pr_data
        |> Enum.map(fn {repo_name, pr_status} ->
          total = Map.get(pr_status, :total, 0)
          open = Map.get(pr_status, :open, 0)
          closed = Map.get(pr_status, :closed, 0)
          merged = Map.get(pr_status, :merged, 0)
          draft = Map.get(pr_status, :draft, 0)
          status = Map.get(pr_status, :status, "Unknown")

          "#{String.pad_trailing(repo_name, 24)} | #{String.pad_leading(to_string(total), 9)} | #{String.pad_leading(to_string(open), 4)} | #{String.pad_leading(to_string(closed), 6)} | #{String.pad_leading(to_string(merged), 6)} | #{String.pad_leading(to_string(draft), 5)} | #{status}"
        end)

      output = [header, separator] ++ rows
      {:ok, Enum.join(output, "\n")}
    end
  end

  defp format_csv_output(pr_data, _opts) do
    if Enum.empty?(pr_data) do
      {:ok, "No repositories found."}
    else
      header = "repository,total_prs,open_prs,closed_prs,merged_prs,draft_prs,status"

      # pr_dataは既にソート済みリストなのでそのまま使用
      rows =
        pr_data
        |> Enum.map(fn {repo_name, pr_status} ->
          total = Map.get(pr_status, :total, 0)
          open = Map.get(pr_status, :open, 0)
          closed = Map.get(pr_status, :closed, 0)
          merged = Map.get(pr_status, :merged, 0)
          draft = Map.get(pr_status, :draft, 0)
          status = Map.get(pr_status, :status, "Unknown")

          "#{repo_name},#{total},#{open},#{closed},#{merged},#{draft},#{status}"
        end)

      output = [header] ++ rows
      {:ok, Enum.join(output, "\n")}
    end
  end

  defp format_json_output(pr_data, _opts) do
    if Enum.empty?(pr_data) do
      {:ok, "[]"}
    else
      # pr_dataは既にソート済みリストなのでそのまま使用
      json_data =
        pr_data
        |> Enum.map(fn {repo_name, pr_status} ->
          %{
            "repository" => repo_name,
            "total_prs" => Map.get(pr_status, :total, 0),
            "open_prs" => Map.get(pr_status, :open, 0),
            "closed_prs" => Map.get(pr_status, :closed, 0),
            "merged_prs" => Map.get(pr_status, :merged, 0),
            "draft_prs" => Map.get(pr_status, :draft, 0),
            "status" => Map.get(pr_status, :status, "Unknown")
          }
        end)

      case Jason.encode(json_data, pretty: true) do
        {:ok, json_string} -> {:ok, json_string}
        {:error, reason} -> {:error, "JSON encoding failed: #{inspect(reason)}"}
      end
    end
  end
end
