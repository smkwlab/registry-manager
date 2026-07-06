defmodule RegistryManager.Commands.List do
  @moduledoc """
  List command implementation for registry-manager v4.

  Replaces the old 'status' command and provides comprehensive repository listing
  with various display modes, sorting options, and output formats.

  Features:
  - Basic mode: Repository names only
  - Long mode (-l/--long): Detailed table with student information
  - Filtering: By repository type (--type)
  - Sorting: Alphabetical (default) or by time (--sort-by-time)
  - Output formats: table (default), csv, json
  - Activity information: Last activity (default in long mode), owner activity, or registry updated
  - Caching: GitHub API responses cached for performance

  ## Timestamp Display (Issue #107)

  By default in long mode, the "Last Activity" (last push time from GitHub) is displayed.
  This can be changed with the following options:

  - `--show-registry-updated`: Show "Registry Updated" instead of "Last Activity"
  - `--show-both-timestamps`: Show both "Last Activity" and "Registry Updated"
  - `--owner-activity` or `-o`: Show "Owner Activity" instead (owner's last push)
  """

  alias RegistryManager.{Cache, Config, GitHubAPI, TimestampManager}

  require Logger

  @valid_formats ["table", "csv", "json"]
  @valid_types ["wr", "ise", "sotsuron", "master", "thesis", "latex", "other"]

  @doc """
  Runs the list command with given arguments and options.

  ## Options
  - `long` (boolean): Show detailed table format (default: Last Activity is displayed)
  - `type` (string): Filter by repository type
  - `format` (string): Output format (table, csv, json)
  - `activity` (boolean): Explicitly request last activity information (default in long mode)
  - `owner_activity` (boolean): Show owner activity instead of last activity
  - `show_registry_updated` (boolean): Show registry updated instead of last activity (Issue #107)
  - `show_both_timestamps` (boolean): Show both last activity and registry updated (Issue #107)
  - `show_type` (boolean): Show repository type column
  - `show_protection` (boolean): Show protection status column
  - `show_student_id` (boolean): Show student ID column
  - `no_names` (boolean): Hide student names
  - `sort_by_time` (boolean): Sort by timestamp instead of name
  - `reverse` (boolean): Reverse sort order
  - `no_cache` (boolean): Bypass cache for activity information

  ## Test Parameters (for testing only)
  - `repositories` (map): Override repository data
  - `csv_data` (list): Override CSV student data
  - `activity_data` (map): Override activity data
  - `use_cache` (boolean): Force cache usage setting
  """
  @spec run(list(), keyword(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(_args, opts, test_params \\ []) do
    with {:ok, validated_opts} <- validate_options(opts),
         {:ok, repositories} <- get_repositories(test_params),
         {:ok, filtered_repos} <- filter_repositories(repositories, validated_opts),
         {:ok, enriched_repo_list} <-
           enrich_repositories(filtered_repos, validated_opts, test_params),
         {:ok, sorted_repo_list} <- sort_repositories(enriched_repo_list, validated_opts),
         {:ok, output} <- format_output(sorted_repo_list, validated_opts, test_params) do
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
    case Keyword.get(opts, :format, "table") do
      format when format in @valid_formats ->
        :ok

      format ->
        {:error, "Invalid format: #{format}. Valid formats: #{Enum.join(@valid_formats, ", ")}"}
    end
  end

  defp validate_type(opts) do
    case Keyword.get(opts, :type) do
      nil -> :ok
      type when type in @valid_types -> :ok
      type -> {:error, "Invalid type: #{type}. Valid types: #{Enum.join(@valid_types, ", ")}"}
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

  defp sort_repositories(repositories, opts) do
    sort_by_time = Keyword.get(opts, :sort_by_time, false)
    activity = Keyword.get(opts, :activity, false)
    owner_activity = Keyword.get(opts, :owner_activity, false)
    show_registry_updated = Keyword.get(opts, :show_registry_updated, false)
    reverse = Keyword.get(opts, :reverse, false)

    # ソート種別を決定（Issue #107: デフォルトはLast Activityでソート）
    # -t が指定された場合のみ時刻ソートを有効化
    sort_type =
      cond do
        # -t --owner-activity
        sort_by_time and owner_activity -> :owner_activity_time
        # -t --show-registry-updated
        sort_by_time and show_registry_updated -> :registry_time
        # -t --activity（明示的）
        sort_by_time and activity -> :activity_time
        # -t のみ（デフォルト: Last Activityでソート）
        sort_by_time -> :activity_time
        # デフォルト（名前順）
        true -> :alphabetical
      end

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

  defp apply_sorting(repos, :activity_time) do
    Enum.sort(repos, fn {name1, data1}, {name2, data2} ->
      activity1 = Map.get(data1, "last_activity")
      activity2 = Map.get(data2, "last_activity")

      compare_timestamps_for_sorting(activity1, activity2, name1, name2)
    end)
  end

  defp apply_sorting(repos, :owner_activity_time) do
    Enum.sort(repos, fn {name1, data1}, {name2, data2} ->
      owner_activity1 = Map.get(data1, "owner_last_activity")
      owner_activity2 = Map.get(data2, "owner_last_activity")

      compare_timestamps_for_sorting(owner_activity1, owner_activity2, name1, name2)
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
    need_csv = need_student_data?(opts)
    need_activity = need_activity_data?(opts)

    csv_data =
      if need_csv do
        get_csv_data(test_params)
      else
        []
      end

    activity_data =
      if need_activity do
        get_activity_data(repo_list, opts, test_params)
      else
        %{}
      end

    enriched =
      Enum.map(repo_list, fn {repo_name, repo_data} ->
        enriched_data =
          repo_data
          |> add_student_info(csv_data)
          |> add_activity_info(repo_name, activity_data)
          |> migrate_legacy_fields()

        {repo_name, enriched_data}
      end)

    {:ok, enriched}
  end

  defp need_student_data?(opts) do
    # long形式または活動情報表示時に学生データが必要
    long_mode =
      Keyword.get(opts, :long, false) ||
        Keyword.get(opts, :activity, false) ||
        Keyword.get(opts, :owner_activity, false)

    long_mode and not Keyword.get(opts, :no_names, false)
  end

  defp need_activity_data?(opts) do
    # Issue #107: デフォルトでLast Activityを表示するため、
    # --show-registry-updatedが指定されていない限り活動データを取得する
    show_registry_updated = Keyword.get(opts, :show_registry_updated, false)
    show_both = Keyword.get(opts, :show_both_timestamps, false)
    activity = Keyword.get(opts, :activity, false)
    owner_activity = Keyword.get(opts, :owner_activity, false)
    long = Keyword.get(opts, :long, false)

    # long形式の場合の活動データ取得判断
    cond do
      # --show-registry-updated のみの場合は活動データ不要
      show_registry_updated and not show_both -> false
      # 明示的に活動情報が指定された場合
      activity or owner_activity -> true
      # --show-both-timestamps の場合は活動データが必要
      show_both -> true
      # long形式のデフォルトは活動データを取得
      long -> true
      true -> false
    end
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

  defp get_activity_data(repositories, opts, test_params) do
    case Keyword.get(test_params, :activity_data) do
      nil ->
        # 実際のGitHub API呼び出し
        use_cache = not Keyword.get(opts, :no_cache, false)
        fetch_activity_data(repositories, use_cache)

      test_activity ->
        test_activity
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

  defp add_activity_info(repo_data, repo_name, activity_data) do
    case Map.get(activity_data, repo_name) do
      nil -> repo_data
      activity -> Map.merge(repo_data, activity)
    end
  end

  defp migrate_legacy_fields(repo_data) do
    TimestampManager.migrate_legacy_timestamps(repo_data)
  end

  defp format_output(repo_list, opts, _test_params) do
    format = Keyword.get(opts, :format, "table")

    # -a (activity) や -o (owner_activity) オプション使用時は自動的にlong形式を有効化
    long_mode =
      Keyword.get(opts, :long, false) ||
        Keyword.get(opts, :activity, false) ||
        Keyword.get(opts, :owner_activity, false)

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

    # 各列の最大幅を計算
    column_widths = calculate_column_widths(header_list, data_rows)

    # ヘッダー行を作成
    header_line = format_row_with_padding(header_list, column_widths)

    # セパレータ行を作成
    separator_line = build_dynamic_separator(column_widths)

    # データ行を作成
    formatted_rows =
      Enum.map(data_rows, fn row ->
        format_row_with_padding(row, column_widths)
      end)

    output =
      [header_line, separator_line | formatted_rows]
      |> Enum.join("\n")

    {:ok, output}
  end

  # Issue #107: Default timestamp display changed to Last Activity
  # activity系オプションの状態に基づいて、どのタイムスタンプを表示するかを決定
  # 新しい優先順位:
  # 1. --show-both-timestamps が指定された場合: Last Activity + Registry Updated
  # 2. --show-registry-updated が指定された場合: Registry Updated のみ
  # 3. --owner-activity が指定された場合: Owner Activity のみ
  # 4. デフォルト: Last Activity のみ
  @spec determine_timestamp_visibility(keyword()) ::
          {false, boolean(), boolean()} | {true, false, boolean()}
  defp determine_timestamp_visibility(opts) do
    show_registry_updated = Keyword.get(opts, :show_registry_updated, false)
    show_both = Keyword.get(opts, :show_both_timestamps, false)
    owner_activity = Keyword.get(opts, :owner_activity, false)

    # activity オプションは明示的に指定された場合のみtrueとする（後方互換性のため）
    activity = Keyword.get(opts, :activity, false)

    cond do
      # --show-both-timestamps が最優先（Last Activity + Registry Updated）
      show_both ->
        {true, false, true}

      # --show-registry-updated が指定された場合（Registry Updated のみ）
      show_registry_updated ->
        {false, false, true}

      # --owner-activity が指定された場合（Owner Activity のみ）
      owner_activity ->
        {false, true, false}

      # --activity が明示的に指定された場合（Last Activity のみ）
      activity ->
        {true, false, false}

      # デフォルト: Last Activity のみ
      true ->
        {true, false, false}
    end
  end

  # 新しい関数: ヘッダーのリストを作成
  defp build_header_list(opts) do
    base_headers = ["Repository"]

    # Issue #92: Single timestamp display rule
    {show_last_activity, show_owner_activity, show_registry_updated} =
      determine_timestamp_visibility(opts)

    base_headers
    |> add_conditional_header("Student ID", Keyword.get(opts, :show_student_id, false))
    |> add_conditional_header("Name", not Keyword.get(opts, :no_names, false))
    |> add_conditional_header("GitHub User", true)
    |> add_conditional_header("Type", Keyword.get(opts, :show_type, false))
    |> add_conditional_header("Protection", Keyword.get(opts, :show_protection, false))
    |> add_conditional_header("Last Activity", show_last_activity)
    |> add_conditional_header("Owner Activity", show_owner_activity)
    |> add_conditional_header("Registry Updated", show_registry_updated)
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
    base_columns = [repo_name]

    # Issue #92: Single timestamp display rule
    {show_last_activity, show_owner_activity, show_registry_updated} =
      determine_timestamp_visibility(opts)

    base_columns
    |> add_conditional_column(
      Map.get(repo_data, "student_id", "N/A"),
      Keyword.get(opts, :show_student_id, false)
    )
    |> add_conditional_column(
      Map.get(repo_data, "student_name", "N/A"),
      not Keyword.get(opts, :no_names, false)
    )
    |> add_conditional_column(format_github_username(repo_data), true)
    |> add_conditional_column(
      Map.get(repo_data, "repository_type", "N/A"),
      Keyword.get(opts, :show_type, false)
    )
    |> add_conditional_column(
      format_protection_status(repo_data),
      Keyword.get(opts, :show_protection, false)
    )
    |> add_conditional_column(
      format_activity_time(repo_data, "last_activity"),
      show_last_activity
    )
    |> add_conditional_column(
      format_activity_time(repo_data, "owner_last_activity"),
      show_owner_activity
    )
    |> add_conditional_column(format_registry_updated_time(repo_data), show_registry_updated)
  end

  defp add_conditional_column(columns, column_value, condition) do
    if condition do
      columns ++ [column_value]
    else
      columns
    end
  end

  # 列幅を計算する関数
  defp calculate_column_widths(headers, data_rows) do
    # 初期値としてヘッダーの表示幅を使用
    initial_widths = Enum.map(headers, &display_width/1)

    # 各データ行の各列の表示幅と比較して最大値を取る
    Enum.reduce(data_rows, initial_widths, fn row, widths ->
      row_widths = Enum.map(row, &display_width/1)

      Enum.zip(widths, row_widths)
      |> Enum.map(fn {current_max, row_width} -> max(current_max, row_width) end)
    end)
  end

  @doc """
  文字列の表示幅を計算します（全角文字を考慮）。

  日本語環境での表示幅を正確に計算するため、
  CJK文字、ひらがな、カタカナ、全角記号などを
  2文字幅として扱います。

  ## Examples

      iex> display_width("Hello")
      5

      iex> display_width("こんにちは")
      10

      iex> display_width("Hello世界")
      9

  """
  def display_width(string) do
    string
    |> String.graphemes()
    |> Enum.reduce(0, fn grapheme, width ->
      width + char_display_width(grapheme)
    end)
  end

  # 個々の文字の表示幅を判定
  defp char_display_width(char) do
    case String.to_charlist(char) do
      [codepoint] -> unicode_display_width(codepoint)
      # 複数コードポイントの場合は1文字幅として扱う
      _ -> 1
    end
  end

  # Unicode文字の表示幅を判定（簡素化版）
  # 注: この実装は、厳密なEast Asian Width準拠ではなく、
  # 日本語環境での一般的な表示に最適化された簡易版です。
  # CJK文字、ひらがな、カタカナ、全角記号、ハングルを
  # 主要な全角文字として扱い、それ以外は半角として扱います。
  # 精度は実用上十分であることがテストで確認されています。
  # 制御文字
  defp unicode_display_width(codepoint) when codepoint <= 0x1F, do: 0
  # ASCII
  defp unicode_display_width(codepoint) when codepoint <= 0x7F, do: 1
  # 制御文字
  defp unicode_display_width(codepoint) when codepoint <= 0x9F, do: 0
  # CJK系全般
  defp unicode_display_width(codepoint) when codepoint >= 0x3000 and codepoint <= 0x9FFF, do: 2
  # 全角記号
  defp unicode_display_width(codepoint) when codepoint >= 0xFF00 and codepoint <= 0xFFEF, do: 2
  # ハングル
  defp unicode_display_width(codepoint) when codepoint >= 0xAC00 and codepoint <= 0xD7AF, do: 2
  # その他デフォルト
  defp unicode_display_width(_codepoint), do: 1

  # パディングを適用して行をフォーマット
  defp format_row_with_padding(columns, widths) do
    columns
    |> Enum.zip(widths)
    |> Enum.map(fn {column, width} ->
      pad_string_with_display_width(column, width)
    end)
    |> Enum.join("  ")
  end

  # 表示幅を考慮したパディング
  defp pad_string_with_display_width(string, target_width) do
    current_width = display_width(string)
    padding_needed = max(0, target_width - current_width)
    string <> String.duplicate(" ", padding_needed)
  end

  # 動的なセパレータを作成
  defp build_dynamic_separator(widths) do
    widths
    |> Enum.map(fn width ->
      String.duplicate("-", width)
    end)
    |> Enum.join("  ")
  end

  defp format_protection_status(repo_data) do
    case Map.get(repo_data, "protection_status") do
      "protected" -> "protected"
      "not_protected" -> "not_protected"
      _ -> "unknown"
    end
  end

  defp format_activity_time(repo_data, field) do
    case Map.get(repo_data, field) do
      nil ->
        "N/A"

      timestamp ->
        case TimestampManager.parse_github_time(timestamp) do
          {:ok, datetime} -> TimestampManager.format_for_display(datetime)
          {:error, _} -> "Invalid"
        end
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
    base_headers = ["repository"]

    # Issue #92: Single timestamp display rule
    {show_last_activity, show_owner_activity, show_registry_updated} =
      determine_timestamp_visibility(opts)

    base_headers
    |> add_conditional_header("student_id", Keyword.get(opts, :show_student_id, false))
    |> add_conditional_header("name", not Keyword.get(opts, :no_names, false))
    |> add_conditional_header("github_username", true)
    |> add_conditional_header("type", Keyword.get(opts, :show_type, false))
    |> add_conditional_header("protection_status", Keyword.get(opts, :show_protection, false))
    |> add_conditional_header("last_activity", show_last_activity)
    |> add_conditional_header("owner_activity", show_owner_activity)
    |> add_conditional_header("registry_updated_at", show_registry_updated)
    |> Enum.join(",")
  end

  defp build_csv_row(repo_name, repo_data, opts) do
    base_values = [repo_name]

    # Issue #92: Single timestamp display rule
    {show_last_activity, show_owner_activity, show_registry_updated} =
      determine_timestamp_visibility(opts)

    base_values
    |> add_conditional_column(
      Map.get(repo_data, "student_id", ""),
      Keyword.get(opts, :show_student_id, false)
    )
    |> add_conditional_column(
      Map.get(repo_data, "student_name", ""),
      not Keyword.get(opts, :no_names, false)
    )
    |> add_conditional_column(format_github_username(repo_data), true)
    |> add_conditional_column(
      Map.get(repo_data, "repository_type", ""),
      Keyword.get(opts, :show_type, false)
    )
    |> add_conditional_column(
      format_protection_status(repo_data),
      Keyword.get(opts, :show_protection, false)
    )
    |> add_conditional_column(
      format_activity_time(repo_data, "last_activity"),
      show_last_activity
    )
    |> add_conditional_column(
      format_activity_time(repo_data, "owner_last_activity"),
      show_owner_activity
    )
    |> add_conditional_column(format_registry_updated_time(repo_data), show_registry_updated)
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
    base_object = %{"repository" => repo_name}

    # Issue #92: Single timestamp display rule
    {show_last_activity, show_owner_activity, show_registry_updated} =
      determine_timestamp_visibility(opts)

    base_object
    |> add_conditional_json_field(
      "student_id",
      Map.get(repo_data, "student_id"),
      Keyword.get(opts, :show_student_id, false)
    )
    |> add_conditional_json_field(
      "name",
      Map.get(repo_data, "student_name"),
      not Keyword.get(opts, :no_names, false)
    )
    |> add_conditional_json_field(
      "github_username",
      get_github_usernames_for_json(repo_data),
      true
    )
    |> add_conditional_json_field(
      "type",
      Map.get(repo_data, "repository_type"),
      Keyword.get(opts, :show_type, false)
    )
    |> add_conditional_json_field(
      "protection_status",
      Map.get(repo_data, "protection_status"),
      Keyword.get(opts, :show_protection, false)
    )
    |> add_conditional_json_field(
      "last_activity",
      format_activity_time(repo_data, "last_activity"),
      show_last_activity
    )
    |> add_conditional_json_field(
      "owner_activity",
      format_activity_time(repo_data, "owner_last_activity"),
      show_owner_activity
    )
    |> add_conditional_json_field(
      "registry_updated_at",
      format_registry_updated_time(repo_data),
      show_registry_updated
    )
  end

  defp add_conditional_json_field(object, field_name, field_value, condition) do
    if condition and field_value != nil do
      Map.put(object, field_name, field_value)
    else
      object
    end
  end

  @spec fetch_activity_data(list(), boolean()) :: map()
  defp fetch_activity_data(repo_list, use_cache) do
    config = Config.load_config()

    # リポジトリ名のリストを作成
    repo_names = Enum.map(repo_list, fn {repo_name, _data} -> repo_name end)

    # 並列実行で各リポジトリの活動情報を取得
    results =
      repo_names
      |> Task.async_stream(
        fn repo_name ->
          fetch_single_repository_activity(repo_name, use_cache, config)
        end,
        max_concurrency: config.api.max_concurrent,
        timeout: config.api.timeout_seconds * 1000,
        ordered: true,
        on_timeout: :kill_task
      )

    # 結果とリポジトリ名をペアにして処理
    results
    |> Enum.zip(repo_names)
    |> Enum.reduce(%{}, fn
      {{:ok, {:ok, activity_data}}, repo_name}, acc ->
        Map.put(acc, repo_name, activity_data)

      {{:ok, {:error, _reason}}, repo_name}, acc ->
        # エラーの場合は空の活動データを設定
        Map.put(acc, repo_name, %{
          "last_activity" => nil,
          "owner_last_activity" => nil
        })

      {{:exit, _reason}, repo_name}, acc ->
        # タイムアウトやクラッシュの場合も空の活動データを設定
        Map.put(acc, repo_name, %{
          "last_activity" => nil,
          "owner_last_activity" => nil
        })

      # その他の予期しないケース
      {unexpected_result, repo_name}, acc ->
        Logger.warning(
          "Unexpected result in parallel activity fetch for #{repo_name}: #{inspect(unexpected_result)}"
        )

        Map.put(acc, repo_name, %{
          "last_activity" => nil,
          "owner_last_activity" => nil
        })
    end)
  end

  @spec fetch_single_repository_activity(String.t(), boolean(), Config.t()) ::
          {:ok, map()} | {:error, String.t()}
  defp fetch_single_repository_activity(repo_name, use_cache, config) do
    if use_cache do
      case Cache.get(repo_name) do
        {:ok, cached_data} ->
          {:ok, cached_data}

        {:error, :cache_miss} ->
          fetch_and_cache_repository_activity(repo_name, config)

        {:error, :cache_expired} ->
          handle_cache_refresh(repo_name, config)

        {:error, reason} ->
          {:error, "Cache error: #{reason}"}
      end
    else
      # --no-cache オプション使用時も取得した最新データをキャッシュに保存
      fetch_and_cache_repository_activity(repo_name, config)
    end
  end

  defp handle_cache_refresh(repo_name, config) do
    case fetch_and_cache_repository_activity(repo_name, config) do
      {:ok, activity_data} ->
        {:ok, activity_data}

      {:error, reason} ->
        Logger.warning("Failed to refresh expired cache for #{repo_name}: #{reason}")
        {:error, "Failed to refresh activity data: #{reason}"}
    end
  end

  defp fetch_and_cache_repository_activity(repo_name, config) do
    case fetch_repository_activity_from_api(repo_name, config) do
      {:ok, activity_data} ->
        # キャッシュに保存
        :ok = Cache.put(repo_name, activity_data)
        {:ok, activity_data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_repository_activity_from_api(repo_name, _config) do
    # GitHub API から活動情報を取得
    case GitHubAPI.get_repository_activity(repo_name) do
      {:ok, general_activity} ->
        # 所有者の活動情報も取得
        case GitHubAPI.get_repository_activity(repo_name, owner_only: true) do
          {:ok, owner_activity} ->
            {:ok,
             %{
               "last_activity" => general_activity,
               "owner_last_activity" => owner_activity
             }}

          {:error, _} ->
            # 所有者の活動情報取得に失敗した場合は一般的な活動情報のみ
            {:ok,
             %{
               "last_activity" => general_activity,
               "owner_last_activity" => nil
             }}
        end

      {:error, reason} ->
        {:error, "Failed to fetch repository activity: #{reason}"}
    end
  end

  @spec get_repositories(keyword()) :: {:ok, map()} | {:error, String.t()}
  defp get_repositories(test_params) do
    case Keyword.get(test_params, :repositories) do
      nil ->
        # 実際のGitHub APIから取得
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
