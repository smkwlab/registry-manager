defmodule RegistryManager.Commands.List do
  @moduledoc """
  List command implementation for registry-manager.

  Provides a registry view: it renders what is recorded in the registry
  (data/registry.json) without making any per-repository GitHub API calls.
  Live monitoring (activity times, PR status, live protection state) is the
  responsibility of thesis-monitor, not this tool.

  Features:
  - Basic mode: Repository names only
  - Long mode (-l/--long): Registry detail table
    (type / GitHub user / protection[recorded] / registry updated)
  - Filtering: By repository type (--type)
  - Archived: archived entries (with `archived_at`) are hidden by default;
    `-a`/`--show-archived` includes them (matches thesis-monitor status)
  - Sorting: Alphabetical (default) or by registry-updated time (--sort time / -t)
  - Output formats: table (default), csv, json

  The only network access is a single read of the registry file itself
  (Contents API via `GitHubAPI.get_repositories_json/0`) — the tool reading
  its own remote write target, which is not per-repository monitoring.
  """

  alias RegistryManager.CLI.Spec
  alias RegistryManager.GitHubAPI
  alias RegistryManager.TimestampManager
  alias ToolKit.Output.Table
  alias ToolKit.Output.TextWidth

  @doc """
  Runs the list command with given arguments and options.

  ## Options
  - `long` (boolean): Show the registry detail table (type / GitHub user /
    protection[recorded] / registry updated)
  - `type` (string): Filter by repository type
  - `format` (string): Output format (table, csv, json)
  - `show_type` (boolean): Show repository type column
  - `show_protection` (boolean): Show recorded protection status column
  - `show_registry_updated` (boolean): Show registry updated column
  - `show_student_id` (boolean): Show student ID column
  - `show_archived` (boolean): Include archived entries (default: active only)
  - `no_names` (boolean): Hide student names
  - `sort` (string): Sort key, "name" (default) or "time" (registry-updated time)
  - `reverse` (boolean): Reverse sort order

  ## Test Parameters (for testing only)
  - `repositories` (map): Override repository data
  - `csv_data` (list): Override CSV student data
  """
  @spec run(list(), keyword(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(_args, opts, test_params \\ []) do
    with {:ok, validated_opts} <- validate_options(opts),
         {:ok, repositories} <- get_repositories(test_params),
         {:ok, active_repos} <- reject_archived(repositories, validated_opts),
         {:ok, filtered_repos} <- filter_repositories(active_repos, validated_opts),
         {:ok, enriched_repo_list} <-
           enrich_repositories(filtered_repos, validated_opts, test_params),
         {:ok, sorted_repo_list} <- sort_repositories(enriched_repo_list, validated_opts),
         {:ok, output} <- format_output(sorted_repo_list, validated_opts) do
      {:ok, output}
    end
  end

  @doc """
  Validates command options.
  """
  @spec validate_options(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def validate_options(opts) do
    with :ok <- validate_format(opts),
         :ok <- validate_type(opts) do
      {:ok, opts}
    end
  end

  defp validate_format(opts) do
    format = Keyword.get(opts, :format, "table")

    if format in Spec.output_formats() do
      :ok
    else
      {:error,
       "Invalid format: #{format}. Valid formats: #{Enum.join(Spec.output_formats(), ", ")}"}
    end
  end

  defp validate_type(opts) do
    type = Keyword.get(opts, :type)

    if is_nil(type) or type in Spec.repo_types() do
      :ok
    else
      {:error, "Invalid type: #{type}. Valid types: #{Enum.join(Spec.repo_types(), ", ")}"}
    end
  end

  # archive 済み（archived_at を持つ）エントリは既定で除外し、現役のみを表示する。
  # --show-archived（-a）指定時は従来どおり全件を対象にする。thesis-monitor の
  # status と挙動を揃えており、archive 済み判定は archived_at の有無で行う。
  defp reject_archived(repositories, opts) do
    if Keyword.get(opts, :show_archived, false) do
      {:ok, repositories}
    else
      active =
        repositories
        |> Enum.reject(fn {_repo_name, repo_data} -> archived?(repo_data) end)
        |> Enum.into(%{})

      {:ok, active}
    end
  end

  defp archived?(repo_data) do
    case Map.get(repo_data, "archived_at") do
      at when is_binary(at) and at != "" -> true
      _ -> false
    end
  end

  defp filter_repositories(repositories, opts) do
    filtered =
      case Keyword.get(opts, :type) do
        nil ->
          repositories

        "thesis" ->
          # Issue #388: thesis shows both sotsuron and master repositories
          Enum.filter(repositories, fn {_repo_name, repo_data} ->
            repo_type = Map.get(repo_data, "repository_type")
            repo_type == "sotsuron" or repo_type == "master"
          end)
          |> Enum.into(%{})

        "other" ->
          # Issue #388: other shows only repositories explicitly typed as "other"
          Enum.filter(repositories, fn {_repo_name, repo_data} ->
            Map.get(repo_data, "repository_type") == "other"
          end)
          |> Enum.into(%{})

        filter_type ->
          # Standard exact match for other types (wr, ise, sotsuron, master)
          Enum.filter(repositories, fn {_repo_name, repo_data} ->
            Map.get(repo_data, "repository_type") == filter_type
          end)
          |> Enum.into(%{})
      end

    {:ok, filtered}
  end

  # ソートは registry のデータだけで完結する:
  # デフォルトは名前順、--sort time（短縮: -t）は registry_updated_at 順。
  defp sort_repositories(repositories, opts) do
    sort_by_time = Keyword.get(opts, :sort) == "time"
    reverse = Keyword.get(opts, :reverse, false)

    sort_type = if sort_by_time, do: :registry_time, else: :alphabetical

    sorted_list =
      repositories
      |> Enum.to_list()
      |> apply_sorting(sort_type)
      |> apply_reverse(reverse)

    {:ok, sorted_list}
  end

  defp apply_sorting(repos, :registry_time) do
    Enum.sort(repos, fn {name1, data1}, {name2, data2} ->
      time1 = get_sort_timestamp(data1)
      time2 = get_sort_timestamp(data2)

      compare_timestamps_for_sorting(time1, time2, name1, name2)
    end)
  end

  defp apply_sorting(repos, :alphabetical) do
    Enum.sort(repos, fn {name1, _data1}, {name2, _data2} ->
      name1 <= name2
    end)
  end

  # タイムスタンプ比較の専用関数
  defp compare_timestamps_for_sorting(time1, time2, name1, name2) do
    case {TimestampManager.parse_github_time(time1), TimestampManager.parse_github_time(time2)} do
      {{:ok, dt1}, {:ok, dt2}} ->
        # 両方とも有効なタイムスタンプ
        case DateTime.compare(dt1, dt2) do
          # dt1 > dt2 (新しい順)
          :gt -> true
          # dt1 < dt2
          :lt -> false
          # 同じ時刻の場合はアルファベット順
          :eq -> name1 <= name2
        end

      {{:ok, _dt1}, {:error, _}} ->
        # time1 は有効、time2 は無効 → time1 を優先
        true

      {{:error, _}, {:ok, _dt2}} ->
        # time1 は無効、time2 は有効 → time2 を優先
        false

      {{:error, _}, {:error, _}} ->
        # 両方とも無効 → アルファベット順
        name1 <= name2
    end
  end

  defp apply_reverse(repos, true), do: Enum.reverse(repos)
  defp apply_reverse(repos, false), do: repos

  defp get_sort_timestamp(repo_data) do
    # 新形式の場合
    case Map.get(repo_data, "registry_updated_at") do
      nil ->
        # レガシー形式の場合
        Map.get(repo_data, "updated_at", Map.get(repo_data, "created_at", "1970-01-01T00:00:00Z"))

      timestamp ->
        timestamp
    end
  end

  defp enrich_repositories(repo_list, opts, test_params) do
    csv_data =
      if need_student_data?(opts) do
        get_csv_data(test_params)
      else
        []
      end

    enriched =
      Enum.map(repo_list, fn {repo_name, repo_data} ->
        {repo_name, add_student_info(repo_data, csv_data)}
      end)

    {:ok, enriched}
  end

  # 学生名は detailed 表示（long / csv / json）でのみ必要。
  # per-repo の GitHub 取得は行わず、CSV 名簿の突合のみ。
  defp need_student_data?(opts) do
    detailed =
      Keyword.get(opts, :long, false) ||
        Keyword.get(opts, :format, "table") in ["csv", "json"]

    detailed and not Keyword.get(opts, :no_names, false)
  end

  defp get_csv_data(test_params) do
    case Keyword.get(test_params, :csv_data) do
      nil ->
        # 実際のCSVファイルから読み込み
        case RegistryManager.Repository.get_all_students_from_csv() do
          {:ok, csv_data} -> csv_data
          {:error, _reason} -> []
        end

      test_csv_data ->
        # テスト用データを使用
        test_csv_data
    end
  end

  defp add_student_info(repo_data, csv_data) do
    student_id = Map.get(repo_data, "student_id")
    github_username = Map.get(repo_data, "github_username")

    student_info =
      Enum.find(csv_data, fn student ->
        csv_student_id = Map.get(student, "student_id")
        csv_github_username = Map.get(student, "github_username")

        student_id_matches?(student_id, csv_student_id) or
          github_username_matches?(github_username, csv_github_username)
      end)

    case student_info do
      nil -> Map.put(repo_data, "student_name", "N/A")
      info -> Map.put(repo_data, "student_name", Map.get(info, "name", "N/A"))
    end
  end

  defp student_id_matches?(student_id, csv_student_id) do
    csv_student_id == student_id
  end

  defp github_username_matches?(usernames, csv_github_username) when is_list(usernames) do
    Enum.any?(usernames, &username_matches?(&1, csv_github_username))
  end

  defp github_username_matches?(username, csv_github_username) when is_binary(username) do
    username_matches?(username, csv_github_username)
  end

  defp github_username_matches?(_username, _csv_github_username), do: false

  defp username_matches?(username, csv_github_username) do
    is_binary(username) and is_binary(csv_github_username) and
      username != "" and csv_github_username != "" and
      username == csv_github_username
  end

  defp format_output(repo_list, opts) do
    format = Keyword.get(opts, :format, "table")
    long_mode = Keyword.get(opts, :long, false)

    case {format, long_mode} do
      {"table", false} -> format_basic_list(repo_list)
      {"table", true} -> format_detailed_table(repo_list, opts)
      {"csv", _} -> format_csv(repo_list, opts)
      {"json", _} -> format_json(repo_list, opts)
    end
  end

  defp format_basic_list(repo_list) do
    output =
      repo_list
      |> Enum.map(fn {repo_name, _repo_data} -> repo_name end)
      |> Enum.join("\n")

    {:ok, output}
  end

  defp format_detailed_table(repo_list, opts) do
    # ヘッダーとデータ行を準備
    header_list = build_header_list(opts)

    # 各行のデータを列のリストとして準備
    data_rows =
      Enum.map(repo_list, fn {repo_name, repo_data} ->
        build_column_data(repo_name, repo_data, opts)
      end)

    {:ok, Table.render(header_list, data_rows)}
  end

  # long 指定時はレジストリ詳細列（type / protection[recorded] / registry updated）を
  # まとめて表示する。個別の --show-* フラグでも同じ列を単独で有効化できる。
  # 表示する列はすべて registry に保存された値で、GitHub は叩かない。
  defp column_visibility(opts) do
    long = Keyword.get(opts, :long, false)

    %{
      student_id: Keyword.get(opts, :show_student_id, false),
      names: not Keyword.get(opts, :no_names, false),
      type: long or Keyword.get(opts, :show_type, false),
      protection: long or Keyword.get(opts, :show_protection, false),
      registry_updated: long or Keyword.get(opts, :show_registry_updated, false)
    }
  end

  # 新しい関数: ヘッダーのリストを作成
  defp build_header_list(opts) do
    vis = column_visibility(opts)

    ["Repository"]
    |> add_conditional_header("Student ID", vis.student_id)
    |> add_conditional_header("Name", vis.names)
    |> add_conditional_header("GitHub User", true)
    |> add_conditional_header("Type", vis.type)
    |> add_conditional_header("Protection (recorded)", vis.protection)
    |> add_conditional_header("Registry Updated", vis.registry_updated)
  end

  defp add_conditional_header(headers, header_name, condition) do
    if condition do
      headers ++ [header_name]
    else
      headers
    end
  end

  # 新しい関数: データ行を列のリストとして作成
  defp build_column_data(repo_name, repo_data, opts) do
    vis = column_visibility(opts)

    [repo_name]
    |> add_conditional_column(Map.get(repo_data, "student_id", "N/A"), vis.student_id)
    |> add_conditional_column(Map.get(repo_data, "student_name", "N/A"), vis.names)
    |> add_conditional_column(format_github_username(repo_data), true)
    |> add_conditional_column(Map.get(repo_data, "repository_type", "N/A"), vis.type)
    |> add_conditional_column(format_protection_status(repo_data), vis.protection)
    |> add_conditional_column(format_registry_updated_time(repo_data), vis.registry_updated)
  end

  defp add_conditional_column(columns, column_value, condition) do
    if condition do
      columns ++ [column_value]
    else
      columns
    end
  end

  @doc """
  文字列の表示幅を計算します（全角文字を考慮）。

  `ToolKit.Output.TextWidth.display_width/1` への委譲。
  """
  def display_width(string), do: TextWidth.display_width(string)

  defp format_protection_status(repo_data) do
    case Map.get(repo_data, "protection_status") do
      "protected" -> "protected"
      "not_protected" -> "not_protected"
      _ -> "unknown"
    end
  end

  defp format_registry_updated_time(repo_data) do
    timestamp =
      Map.get(repo_data, "registry_updated_at") ||
        Map.get(repo_data, "updated_at") ||
        Map.get(repo_data, "created_at")

    case timestamp do
      nil ->
        "N/A"

      ts ->
        case TimestampManager.parse_github_time(ts) do
          {:ok, datetime} -> TimestampManager.format_for_display(datetime)
          {:error, _} -> "Invalid"
        end
    end
  end

  defp format_csv(repo_list, opts) do
    headers = build_csv_headers(opts)

    rows =
      Enum.map(repo_list, fn {repo_name, repo_data} ->
        build_csv_row(repo_name, repo_data, opts)
      end)

    output =
      [headers | rows]
      |> Enum.join("\n")

    {:ok, output}
  end

  defp build_csv_headers(opts) do
    vis = column_visibility(opts)

    ["repository"]
    |> add_conditional_header("student_id", vis.student_id)
    |> add_conditional_header("name", vis.names)
    |> add_conditional_header("github_username", true)
    |> add_conditional_header("type", vis.type)
    |> add_conditional_header("protection_status", vis.protection)
    |> add_conditional_header("registry_updated_at", vis.registry_updated)
    |> Enum.join(",")
  end

  defp build_csv_row(repo_name, repo_data, opts) do
    vis = column_visibility(opts)

    [repo_name]
    |> add_conditional_column(Map.get(repo_data, "student_id", ""), vis.student_id)
    |> add_conditional_column(Map.get(repo_data, "student_name", ""), vis.names)
    |> add_conditional_column(format_github_username(repo_data), true)
    |> add_conditional_column(Map.get(repo_data, "repository_type", ""), vis.type)
    |> add_conditional_column(format_protection_status(repo_data), vis.protection)
    |> add_conditional_column(format_registry_updated_time(repo_data), vis.registry_updated)
    |> Enum.map(&escape_csv_value/1)
    |> Enum.join(",")
  end

  defp escape_csv_value(value) do
    if String.contains?(value, ",") or String.contains?(value, "\"") do
      "\"#{String.replace(value, "\"", "\"\"")}\""
    else
      value
    end
  end

  defp format_json(repo_list, opts) do
    data =
      Enum.map(repo_list, fn {repo_name, repo_data} ->
        build_json_object(repo_name, repo_data, opts)
      end)

    case Jason.encode(data, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, "JSON encoding failed: #{inspect(reason)}"}
    end
  end

  defp build_json_object(repo_name, repo_data, opts) do
    vis = column_visibility(opts)

    %{"repository" => repo_name}
    |> add_conditional_json_field("student_id", Map.get(repo_data, "student_id"), vis.student_id)
    |> add_conditional_json_field("name", Map.get(repo_data, "student_name"), vis.names)
    |> add_conditional_json_field(
      "github_username",
      get_github_usernames_for_json(repo_data),
      true
    )
    |> add_conditional_json_field("type", Map.get(repo_data, "repository_type"), vis.type)
    |> add_conditional_json_field(
      "protection_status",
      Map.get(repo_data, "protection_status"),
      vis.protection
    )
    |> add_conditional_json_field(
      "registry_updated_at",
      format_registry_updated_time(repo_data),
      vis.registry_updated
    )
  end

  defp add_conditional_json_field(object, field_name, field_value, condition) do
    if condition and field_value != nil do
      Map.put(object, field_name, field_value)
    else
      object
    end
  end

  @spec get_repositories(keyword()) :: {:ok, map()} | {:error, String.t()}
  defp get_repositories(test_params) do
    case Keyword.get(test_params, :repositories) do
      nil ->
        # レジストリ本体（registry.json）を Contents API で 1 回だけ取得する。
        # これは書き手が自分の書き込み先を読む動作で、per-repo 監視ではない。
        case GitHubAPI.get_repositories_json() do
          {:ok, {data, _sha}} -> {:ok, data}
          {:error, reason} -> {:error, "Failed to fetch repositories: #{reason}"}
        end

      test_repos ->
        {:ok, test_repos}
    end
  end

  # GitHub username フォーマット関数
  # 単一ユーザーの場合はそのまま表示し、複数ユーザーの場合はカンマ区切りで表示
  # これにより表示の読みやすさを保ちつつ、複数オーナーも分かりやすく表示
  defp format_github_username(repo_data) do
    case Map.get(repo_data, "github_username") do
      nil ->
        "N/A"

      usernames when is_list(usernames) ->
        case usernames do
          [] -> "N/A"
          # 単一ユーザーは読みやすさのためそのまま表示
          [single] -> single
          # 複数ユーザーはカンマ区切り
          multiple -> Enum.join(multiple, ", ")
        end

      username when is_binary(username) and username != "" ->
        username

      _ ->
        "N/A"
    end
  end

  defp get_github_usernames_for_json(repo_data) do
    case Map.get(repo_data, "github_username") do
      nil -> nil
      usernames when is_list(usernames) -> usernames
      username when is_binary(username) -> username
      _ -> nil
    end
  end
end
