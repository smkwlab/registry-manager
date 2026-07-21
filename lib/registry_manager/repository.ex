defmodule RegistryManager.Repository do
  @moduledoc """
  リポジトリ管理のビジネスロジック - 外部依存なし

  このモジュールはリポジトリ管理の核となるビジネスロジックを担当します。
  データ永続化は DataStore モジュールに委譲し、外部依存を完全に分離します。
  """

  alias RegistryManager.{Config, Validation}
  alias RegistryManager.Repository.{DataStore, Display, ErrorHandler}

  @doc """
  新しいリポジトリエントリを構築（ビジネスロジック）

  review_flow が nil の場合はタイプ由来の既定値
  （`Validation.default_review_flow/1`）を採用する。
  """
  def build_new_entry(
        student_id,
        repo_type,
        timestamp,
        github_username \\ nil,
        review_flow \\ nil
      ) do
    base_entry = %{
      "student_id" => student_id,
      "repository_type" => repo_type,
      "created_at" => timestamp,
      "registry_updated_at" => timestamp,
      "review_flow" =>
        if(is_nil(review_flow),
          do: Validation.default_review_flow(repo_type),
          else: review_flow
        )
    }

    case github_username do
      nil ->
        base_entry

      username when is_binary(username) and username != "" ->
        Map.put(base_entry, "github_username", username)

      _ ->
        base_entry
    end
  end

  @doc """
  リポジトリ追加のバリデーション（ビジネスロジック）
  """
  def validate_add_request(repo_name, student_id, repo_type) do
    with :ok <- Validation.validate_student_id(student_id),
         :ok <- Validation.validate_repository_name(repo_name, student_id),
         :ok <- Validation.validate_repository_type(repo_type) do
      :ok
    end
  end

  @doc """
  推論モード用のバリデーション（リポジトリ名の検証を除外）
  """
  def validate_add_request_for_inference(repo_name, student_id, repo_type) do
    with :ok <- Validation.validate_student_id(student_id),
         :ok <- Validation.validate_repository_type(repo_type) do
      :ok
    else
      {:error, msg} when is_binary(msg) ->
        {:error, "#{msg} (repository: #{repo_name}, inferred_student_id: #{student_id})"}
    end
  end

  @doc """
  タイムスタンプの取得と検証（ビジネスロジック）
  """
  def get_validated_timestamp(opts) do
    case Keyword.get(opts, :timestamp) do
      nil ->
        {:ok, DateTime.utc_now() |> DateTime.to_iso8601()}

      timestamp when is_binary(timestamp) ->
        validate_timestamp_format(timestamp)

      _ ->
        {:error, "Timestamp must be a string"}
    end
  end

  @doc """
  CSVファイルから GitHub username を取得
  """
  def get_github_username_from_csv(student_id) do
    case read_csv_file() do
      {:ok, content} ->
        parse_github_username_from_csv(content, student_id)

      {:error, :not_configured} ->
        {:error, "CSV file not configured"}

      {:error, _reason} ->
        {:error, "CSV file not accessible"}
    end
  end

  # csv_path 未設定（nil）の場合は {:error, :not_configured} を返す。
  # 読み込み失敗時はエラーメッセージ生成用にパスも返す。
  defp read_csv_file do
    case get_csv_file_path() do
      nil ->
        {:error, :not_configured}

      csv_path ->
        case File.read(csv_path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, {:read_failed, csv_path, reason}}
        end
    end
  end

  defp get_csv_file_path do
    case get_env_mode() do
      :test ->
        # テストで別レイアウトの fixture を検証できるよう、上書きパスを許可する
        Application.get_env(:registry_manager, :csv_path_override) ||
          Path.join([File.cwd!(), "test/fixtures/test_students.csv"])

      _ ->
        case Config.load_config().csv_path do
          nil -> nil
          csv_path -> Path.expand(csv_path)
        end
    end
  end

  # Get environment mode - works in both test and escript contexts
  defp get_env_mode do
    case Application.get_env(:registry_manager, :env) do
      :test ->
        :test

      nil ->
        :prod

      _ ->
        try do
          Mix.env()
        rescue
          UndefinedFunctionError -> :prod
        end
    end
  end

  # 名簿 CSV の論理カラムとヘッダ行での列名の対応（Issue #31）。
  # 実運用 CSV は先頭に「卒業年度」「修了年度」等の列が加わり列位置が変動するため、
  # 列インデックスをハードコードせず、ヘッダ名から解決して列順の変化に強くする。
  @csv_column_names %{
    student_id: "学籍番号",
    graduate_student_id: "大学院学籍番号",
    student_name: "学生氏名",
    github_username: "GitHub",
    graduation_year: "卒業年度",
    completion_year: "修了年度"
  }

  # 学生の突合キーになりうる学籍番号の列。大学院生は「学籍番号」列に学部時代の
  # 番号、「大学院学籍番号」列に院の番号が入るため、両方を突合候補とする（先頭優先）。
  @csv_student_id_columns [:student_id, :graduate_student_id]

  # CSV の内容をヘッダから解決した {列名→index マップ, データ行リスト} に分解する。
  # 実運用 CSV は CRLF 改行を含む場合があるため \r?\n で分割する（Issue #31）。
  defp split_csv_content(content) do
    case String.split(content, ~r/\r?\n/) do
      [header | rows] -> {resolve_csv_columns(header), rows}
      [] -> {%{}, []}
    end
  end

  # ヘッダ行を論理カラム名 → 列インデックスのマップに変換する。
  # 該当する列名が無い場合はそのカラムを nil とし、以降の突合では未取得として扱う。
  defp resolve_csv_columns(header_line) do
    headers =
      header_line
      |> String.split(",")
      |> Enum.map(&String.trim/1)

    Map.new(@csv_column_names, fn {key, name} ->
      {key, Enum.find_index(headers, &(&1 == name))}
    end)
  end

  # 解決済みの列マップから 1 行分の指定カラム値を取り出す（trim 済み、無ければ nil）。
  defp csv_field(parts, columns, key) do
    case Map.get(columns, key) do
      nil -> nil
      index -> parts |> Enum.at(index) |> trim_csv_value()
    end
  end

  defp trim_csv_value(nil), do: nil
  defp trim_csv_value(value), do: String.trim(value)

  # 1 行から突合対象となる学籍番号を正規化して列挙する（非空・先頭優先）。
  # 正規化後に uniq することで、学部/院番号が同一キーに正規化される稀なケースも吸収する。
  defp csv_student_ids(parts, columns) do
    @csv_student_id_columns
    |> Enum.map(&csv_field(parts, columns, &1))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&normalize_student_id_for_comparison/1)
    |> Enum.uniq()
  end

  defp parse_github_username_from_csv(content, target_student_id) do
    {columns, rows} = split_csv_content(content)

    rows
    |> Enum.find_value(fn line ->
      case parse_csv_line_for_github(line, target_student_id, columns) do
        {:ok, github_username} -> github_username
        :not_found -> nil
      end
    end)
    |> case do
      nil -> {:error, "Student not found in CSV"}
      github_username -> {:ok, github_username}
    end
  end

  defp parse_csv_line_for_github(line, target_student_id, columns) do
    parts = String.split(line, ",")
    student_ids = csv_student_ids(parts, columns)
    github_username = csv_field(parts, columns, :github_username)
    normalized_target = normalize_student_id_for_comparison(target_student_id)

    if is_binary(github_username) and github_username != "" and
         normalized_target in student_ids do
      {:ok, github_username}
    else
      :not_found
    end
  end

  defp normalize_student_id_for_comparison(student_id) do
    # Convert formats like "80JK059" to "k80jk059" and "k80jk059" stays as is
    case String.downcase(student_id) do
      "k" <> _ = already_normalized -> already_normalized
      id when byte_size(id) > 0 -> "k" <> String.downcase(id)
      _ -> student_id
    end
  end

  @doc """
  コミットメッセージの構築（ビジネスロジック）
  """
  def build_commit_message(
        title,
        repo_name,
        student_id,
        repo_type,
        tool_name,
        change_detail \\ nil
      ) do
    masked_student_id = mask_student_id(student_id)
    updated_at = DateTime.utc_now() |> DateTime.to_string()

    base_message = """
    #{title}

    Repository: #{repo_name}
    Student ID: #{masked_student_id}
    Type: #{repo_type}
    Updated: #{updated_at}

    Processed via #{tool_name}.
    """

    if change_detail do
      String.replace(base_message, "Processed via", "Change: #{change_detail}\n\nProcessed via")
    else
      base_message
    end
  end

  @doc """
  リポジトリ名から情報を推論してリポジトリを追加

  GitHub APIからリポジトリ情報を取得し、作成者からCSVで学生IDを特定する。
  CSVで見つからない場合はリポジトリ名から推論する。
  """
  def add_with_inference(repo_name, opts \\ []) do
    with {:ok, inferred_data} <- infer_repository_data(repo_name, opts) do
      # Remove org prefix from repo_name for storage
      base_repo_name = String.replace(repo_name, ~r{^[^/]+/}, "")

      # --type による明示指定は名前からの推論より優先する
      # （poster など、リポジトリ名に規則がなく推論できないタイプのため）
      inferred_data = %{inferred_data | repo_type: opts[:type] || inferred_data.repo_type}

      with :ok <-
             validate_add_request_for_inference(
               base_repo_name,
               inferred_data.student_id,
               inferred_data.repo_type
             ) do
        # Add inference_mode flag and github_username to options
        inference_opts =
          opts
          |> Keyword.put(:inference_mode, true)
          |> Keyword.put(:github_username, inferred_data.github_username)

        add(base_repo_name, inferred_data.student_id, inferred_data.repo_type, inference_opts)
      end
    end
  end

  @doc """
  リポジトリ情報を追加

  ## パラメータ
  - `repo_name`: リポジトリ名
  - `student_id`: 学生ID 
  - `repo_type`: リポジトリタイプ (wr, ise, latex, sotsuron, thesis)
  - `opts`: オプション（キーワードリスト）

  ## オプション
  - `:dry_run` - 実際の変更を行わないドライランモード (boolean, default: false)
  - `:verbose` - 詳細な出力を表示 (boolean, default: false)
  - `:timestamp` - テスト用の固定タイムスタンプ (string, format: "YYYY-MM-DD HH:MM:SS UTC")
  """
  def add(repo_name, student_id, repo_type, opts \\ []) do
    # Use inference validation if this was called from inference mode
    validation_result =
      if opts[:inference_mode] do
        validate_add_request_for_inference(repo_name, student_id, repo_type)
      else
        validate_add_request(repo_name, student_id, repo_type)
      end

    with :ok <- validation_result,
         {:ok, timestamp} <- get_validated_timestamp(opts) do
      if opts[:dry_run] do
        handle_dry_run_add(repo_name, timestamp, opts)
      else
        # Get GitHub username from inference data if available, otherwise from CSV or repository
        github_username =
          opts[:github_username] ||
            get_github_username_for_add(repo_name, student_id, opts)

        entry =
          build_new_entry(student_id, repo_type, timestamp, github_username, opts[:review_flow])

        commit_message =
          build_commit_message(
            "Add repository: #{repo_name}",
            repo_name,
            student_id,
            repo_type,
            "registry-manager"
          )

        # 外部依存はDataStoreに委譲
        DataStore.save_entry(repo_name, entry, commit_message)
      end
    end
  end

  defp handle_dry_run_add(repo_name, timestamp, opts) do
    message = "[DRY-RUN] リポジトリ情報を追加: #{repo_name}"

    if opts[:verbose] do
      {:ok, message <> " (created_at: #{timestamp})"}
    else
      {:ok, message}
    end
  end

  @doc """
  リポジトリ情報を更新
  """
  def update(repo_name, field, value, opts \\ []) do
    with {:ok, normalized_value} <- normalize_update_value(field, value) do
      if opts[:dry_run] do
        {:ok, "[DRY-RUN] リポジトリ情報を更新: #{repo_name} (#{field} = #{value})"}
      else
        perform_update(repo_name, field, normalized_value)
      end
    end
  end

  # review_flow は boolean フィールドのため、CLI から渡される文字列を変換する
  defp normalize_update_value("review_flow", "true"), do: {:ok, true}
  defp normalize_update_value("review_flow", "false"), do: {:ok, false}

  defp normalize_update_value("review_flow", value),
    do: {:error, "review_flow の値が不正です: #{value}（true または false を指定してください）"}

  defp normalize_update_value(_field, value), do: {:ok, value}

  defp perform_update(repo_name, field, value) do
    case DataStore.get_all_entries() do
      {:ok, current_data} ->
        update_existing_repository(current_data, repo_name, field, value)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_existing_repository(current_data, repo_name, field, value) do
    case Map.get(current_data, repo_name) do
      nil ->
        ErrorHandler.handle_repository_not_found(repo_name)

      repo_info ->
        commit_message =
          build_commit_message(
            "Update repository: #{repo_name}",
            repo_name,
            repo_info["student_id"],
            repo_info["repository_type"],
            "registry-manager",
            "#{field} = #{value}"
          )

        DataStore.update_entry(repo_name, field, value, commit_message)
    end
  end

  @doc """
  統計情報の計算（ビジネスロジック）
  """
  def calculate_statistics(data) do
    total_count = map_size(data)

    type_counts =
      data
      |> Enum.group_by(fn {_repo, info} -> info["repository_type"] end)
      |> Enum.map(fn {type, repos} -> {type, length(repos)} end)
      |> Enum.into(%{})

    protection_count =
      data
      |> Enum.count(fn {_repo, info} -> info["protection_status"] == "protected" end)

    %{
      total: total_count,
      type: type_counts,
      protected: protection_count
    }
  end

  @doc """
  リポジトリ削除のためのghコマンドを生成
  安全のため確認プロンプト付き（--confirmは非推奨のため削除）

  github_org 未設定時は明示エラーを返す（issue #45、"gh repo delete /repo" のような
  誤ったコマンド生成を防ぐ）。
  """
  @spec build_github_deletion_command(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def build_github_deletion_command(repo_name) do
    with {:ok, org} <- Config.require_github_org() do
      {:ok, "gh repo delete #{org}/#{repo_name}"}
    end
  end

  @doc """
  ブランチ保護設定完了をマーク
  """
  def mark_protected(repo_name, opts \\ []) do
    update(repo_name, "protection_status", "protected", opts)
  end

  # プライベートヘルパー関数（ビジネスロジック）

  defp validate_timestamp_format(timestamp) do
    if Regex.match?(~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC$/, timestamp) do
      validate_timestamp_date(timestamp)
    else
      {:error, "Timestamp must be in format: YYYY-MM-DD HH:MM:SS UTC"}
    end
  end

  defp validate_timestamp_date(timestamp) do
    case DateTime.from_iso8601(String.replace(timestamp, " UTC", "Z")) do
      {:ok, _datetime, _offset} ->
        {:ok, timestamp}

      {:error, _reason} ->
        {:error, "Invalid timestamp format or non-existent date"}
    end
  end

  defp mask_student_id(student_id) when is_binary(student_id) and byte_size(student_id) > 2 do
    String.slice(student_id, 0, 2) <> String.duplicate("*", byte_size(student_id) - 2)
  end

  defp mask_student_id(student_id), do: student_id

  @doc """
  リポジトリ情報をレジストリから削除
  """
  def remove(repo_name, opts \\ []) do
    if opts[:dry_run] do
      handle_dry_run_remove(repo_name, opts)
    else
      perform_remove(repo_name, opts)
    end
  end

  defp handle_dry_run_remove(repo_name, opts) do
    base_message = "[DRY-RUN] リポジトリ情報を削除: #{repo_name}"

    if opts[:delete_github_repo] do
      with {:ok, github_command} <- build_github_deletion_command(repo_name) do
        message = "#{base_message}\n[DRY-RUN] GitHubリポジトリ削除コマンド: #{github_command}"
        {:ok, message}
      end
    else
      {:ok, base_message}
    end
  end

  defp perform_remove(repo_name, opts) do
    case DataStore.entry_exists?(repo_name) do
      true ->
        perform_registry_removal(repo_name, opts)

      false ->
        {:error, "Repository '#{repo_name}' not found in registry"}
    end
  end

  defp perform_registry_removal(repo_name, opts) do
    case DataStore.get_all_entries() do
      {:ok, current_data} ->
        execute_registry_deletion(current_data, repo_name, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_registry_deletion(current_data, repo_name, opts) do
    case Map.get(current_data, repo_name) do
      nil ->
        {:error, "Repository not found: #{repo_name}"}

      repo_info ->
        commit_message = build_deletion_commit_message(repo_name, repo_info)
        perform_registry_deletion(repo_name, commit_message, opts)
    end
  end

  defp perform_registry_deletion(repo_name, commit_message, opts) do
    case DataStore.delete_entry(repo_name, commit_message) do
      {:ok, result} ->
        build_deletion_response(result, repo_name, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_deletion_response(result, repo_name, opts) do
    if opts[:delete_github_repo] do
      with {:ok, github_command} <- build_github_deletion_command(repo_name) do
        message =
          "Registry updated successfully. To delete the GitHub repository, run:\n#{github_command}"

        {:ok, message}
      end
    else
      {:ok, result}
    end
  end

  defp build_deletion_commit_message(repo_name, repo_info) do
    build_commit_message(
      "Remove repository: #{repo_name}",
      repo_name,
      repo_info["student_id"],
      repo_info["repository_type"],
      "registry-manager"
    )
  end

  @doc """
  リポジトリ状況を表示
  """
  def show_status(repo_name, _opts \\ []) do
    case DataStore.get_all_entries() do
      {:ok, current_data} ->
        show_repository_info(current_data, repo_name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp show_repository_info(current_data, repo_name) do
    if repo_name do
      show_specific_repository(current_data, repo_name)
    else
      stats = calculate_statistics(current_data)
      {:ok, Display.format_statistics(stats)}
    end
  end

  defp show_specific_repository(current_data, repo_name) do
    case Map.get(current_data, repo_name) do
      nil ->
        ErrorHandler.handle_repository_not_found(repo_name)

      repo_info ->
        {:ok, Display.format_repository_info(repo_name, repo_info)}
    end
  end

  @doc """
  リポジトリ一覧を表示
  """
  def list_repositories(filter, _opts \\ []) do
    case DataStore.get_all_entries() do
      {:ok, current_data} ->
        filtered_data = filter_repositories(current_data, filter)
        formatted_list = Jason.encode!(filtered_data, pretty: true)
        output = Display.format_repository_list(formatted_list, filter)
        {:ok, output}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp filter_repositories(current_data, filter) do
    if filter do
      current_data
      |> Enum.filter(fn {_repo_name, repo_info} ->
        repo_info["repository_type"] == filter
      end)
      |> Enum.into(%{})
    else
      current_data
    end
  end

  # 推論関連のプライベート関数

  defp infer_repository_data(repo_name, opts) do
    with {:ok, full_repo_name} <- ensure_full_repo_name(repo_name),
         {:ok, repo_info} <- RegistryManager.GitHubAPI.get_repository_info(full_repo_name),
         {:ok, github_owner} <- get_actual_repository_developer(full_repo_name, repo_info, opts) do
      build_repository_data(repo_name, repo_info, github_owner, opts)
    else
      error -> error
    end
  end

  defp build_repository_data(repo_name, repo_info, github_owner, opts) do
    with {:ok, student_id} <- get_student_id_from_github_owner(github_owner, repo_name, opts),
         {:ok, repo_type} <- infer_repository_type(repo_name) do
      {:ok,
       %{
         student_id: student_id,
         repo_type: repo_type,
         github_username: github_owner,
         created_at: repo_info["created_at"]
       }}
    else
      {:error, "Cannot determine student ID"} ->
        {:error, "Cannot determine student ID for #{github_owner}"}

      error ->
        error
    end
  end

  # 既に owner/repo 形式ならそのまま、そうでなければ github_org を前置する。
  # github_org 未設定時は明示エラー（issue #45、"/repo" への静かな誤対象を防ぐ）。
  defp ensure_full_repo_name(repo_name) do
    if String.contains?(repo_name, "/") do
      {:ok, repo_name}
    else
      with {:ok, org} <- Config.require_github_org() do
        {:ok, "#{org}/#{repo_name}"}
      end
    end
  end

  defp extract_repository_owner(repo_info, _repo_name \\ nil) do
    case repo_info do
      %{"owner" => %{"login" => owner_login}} ->
        {:ok, owner_login}

      _ ->
        {:error, "Cannot extract repository owner"}
    end
  end

  @doc """
  リポジトリの実際の開発者を特定
  組織所有の場合はコミット履歴から実際の開発者を特定
  """
  def get_actual_repository_developer(repo_name, repo_info, opts \\ []) do
    case extract_repository_owner(repo_info) do
      {:ok, owner_login} ->
        handle_repository_owner(repo_name, owner_login, opts)

      error ->
        error
    end
  end

  defp handle_repository_owner(repo_name, owner_login, opts) do
    alias RegistryManager.GitHubAPI.Parser

    if Parser.organization_owner?(owner_login) do
      handle_organization_repository(repo_name, owner_login, opts)
    else
      {:ok, owner_login}
    end
  end

  defp handle_organization_repository(repo_name, owner_login, opts) do
    log_verbose(opts, "組織所有リポジトリを検出: #{owner_login}。コミット履歴から実際の開発者を特定中...")

    case RegistryManager.GitHubAPI.get_actual_developer(repo_name) do
      {:ok, actual_developer} ->
        log_verbose(opts, "実際の開発者を特定: #{actual_developer}")
        {:ok, actual_developer}

      {:error, reason} ->
        log_verbose(opts, "コミット履歴からの開発者特定に失敗: #{reason}。リポジトリ所有者を使用: #{owner_login}")
        {:ok, owner_login}
    end
  end

  @doc """
  add操作時のGitHub username取得
  CSVから取得を試み、失敗した場合はリポジトリから推論
  """
  def get_github_username_for_add(repo_name, student_id, opts \\ []) do
    case get_github_username_from_csv(student_id) do
      {:ok, username} ->
        log_verbose(
          opts,
          "GitHub username '#{username}' found in CSV for student '#{student_id}'"
        )

        username

      {:error, _} ->
        log_verbose(
          opts,
          "GitHub username not found in CSV for '#{student_id}'. Attempting repository inference..."
        )

        fallback_to_repository_inference(repo_name, opts)
    end
  end

  defp fallback_to_repository_inference(repo_name, opts) do
    with {:ok, full_repo_name} <- ensure_full_repo_name(repo_name),
         {:ok, repo_info} <- RegistryManager.GitHubAPI.get_repository_info(full_repo_name) do
      extract_github_username_from_repo_info(full_repo_name, repo_info, opts)
    else
      {:error, reason} ->
        # github_org 未設定エラー（issue #45）も含め理由をログに残す。推論は best-effort
        # なので契約どおり nil を返し、呼び出し側は username 未特定として続行する。
        log_verbose(opts, "Repository not accessible for GitHub username inference: #{reason}")
        nil
    end
  end

  defp extract_github_username_from_repo_info(full_repo_name, repo_info, opts) do
    case get_actual_repository_developer(full_repo_name, repo_info, opts) do
      {:ok, github_username} ->
        log_verbose(opts, "Inferred GitHub username '#{github_username}' from repository")
        github_username

      {:error, _} ->
        log_verbose(opts, "Failed to infer GitHub username from repository")
        nil
    end
  end

  defp log_verbose(opts, message) do
    if opts[:verbose] do
      require Logger
      Logger.info(message)
    end
  end

  defp get_student_id_from_github_owner(github_owner, _repo_name, opts) do
    # Step 1: CSVからGitHub IDで検索
    case get_student_id_from_csv_by_github(github_owner) do
      {:ok, student_id} ->
        if opts[:verbose] do
          require Logger
          Logger.info("GitHub ID '#{github_owner}' → 学生ID '#{student_id}' (CSVから取得)")
        end

        {:ok, student_id}

      {:error, _reason} ->
        # CSVに見つからない場合はエラーを返す（リポジトリ名からの推論は不可能）
        if opts[:verbose] do
          require Logger
          Logger.info("CSVに GitHub ID '#{github_owner}' が見つかりません。")
        end

        {:error, "Cannot determine student ID for #{github_owner}"}
    end
  end

  @doc """
  CSVファイルからGitHub usernameで学生IDを検索
  """
  def get_student_id_from_csv_by_github(github_username) do
    case read_csv_file() do
      {:ok, content} ->
        parse_student_id_from_github_username(content, github_username)

      {:error, :not_configured} ->
        {:error, "CSV file not configured"}

      {:error, _reason} ->
        {:error, "CSV file not accessible"}
    end
  end

  defp parse_student_id_from_github_username(content, target_username) do
    {columns, rows} = split_csv_content(content)

    rows
    |> Enum.find_value(&parse_csv_line_for_username(&1, target_username, columns))
    |> case do
      nil -> {:error, "GitHub username not found in CSV"}
      result -> result
    end
  end

  defp parse_csv_line_for_username(line, target_username, columns) do
    # 空行はスキップ
    if String.trim(line) == "" do
      nil
    else
      parts = String.split(line, ",")
      student_ids = csv_student_ids(parts, columns)
      github_username = csv_field(parts, columns, :github_username)

      # 逆引きは学籍番号（学部）を優先して 1 つ返す（先頭が学部番号）。
      if github_username == target_username and student_ids != [] do
        {:ok, List.first(student_ids)}
      end
    end
  end

  @doc """
  CSVファイルから全学生データを読み込み、List コマンドで使用可能な形式に変換

  大学院生は学部/院の 2 つの学籍番号を持つため、同一人物が student_id ごとに
  複数エントリとして返る場合がある（name / github_username は各エントリで同一）。
  呼び出し元は student_id をキーにした突合（例: `Enum.find/2`）を前提としており、
  重複排除は不要。全学生の一意カウント等が必要な場合は student_id で uniq すること。
  """
  def get_all_students_from_csv do
    case read_csv_file() do
      {:ok, content} ->
        try do
          students = parse_all_students_from_csv(content)
          {:ok, students}
        rescue
          error ->
            {:error, "CSV parsing failed: #{Exception.message(error)}"}
        end

      {:error, :not_configured} ->
        {:error, "CSV file not configured (set csv_path to enable name resolution)"}

      {:error, {:read_failed, csv_path, reason}} ->
        {:error, "CSV file not accessible at '#{csv_path}': #{inspect(reason)}"}
    end
  end

  defp parse_all_students_from_csv(content) do
    {columns, rows} = split_csv_content(content)

    Enum.flat_map(rows, &parse_csv_line_for_student(&1, columns))
  end

  @doc """
  名簿 CSV を「1 人 1 エントリ」の構造化リストとして読み込む（卒業処理の判定用）。

  `get_all_students_from_csv/0` が student_id ごとに行を展開するのに対し、こちらは
  学部/院の学籍番号を `student_ids` にまとめ、卒業年度・修了年度・大学院学籍番号も
  含めて 1 人 1 エントリで返す。`RegistryManager.Archive.Classifier` が registry と
  結合して卒業判定を行うための入力。

  各エントリ:
  `%{student_ids: [正規化済み...], name, github, graduation_year, completion_year,
     graduate_student_id}`

  値が空欄の列は空文字列（列自体が無ければ nil）。学籍番号を 1 つも持たない行
  （教員・空行）はスキップする。

  制約: 行の分割は既存の名簿パース（`parse_csv_line_for_student` 等）と同じく
  単純な `String.split(line, ",")` で行うため、クォートで囲まれたフィールドや
  フィールド内カンマ（例: 氏名 "山田, 太郎"）は正しく扱えない。突合・判定に使う
  列（学籍番号・大学院学籍番号・氏名・GitHub・卒業/修了年度）はカンマを含まない
  運用前提。堅牢な CSV パースが必要になった場合は名簿パース全体を別途対応する。
  """
  @spec load_roster() :: {:ok, [map()]} | {:error, String.t()}
  def load_roster do
    case read_csv_file() do
      {:ok, content} ->
        {:ok, parse_roster_from_csv(content)}

      {:error, :not_configured} ->
        {:error, "CSV file not configured (set csv_path to enable graduation classification)"}

      {:error, {:read_failed, csv_path, reason}} ->
        {:error, "CSV file not accessible at '#{csv_path}': #{inspect(reason)}"}
    end
  end

  defp parse_roster_from_csv(content) do
    {columns, rows} = split_csv_content(content)

    Enum.flat_map(rows, &parse_csv_line_for_roster(&1, columns))
  end

  defp parse_csv_line_for_roster(line, columns) do
    if String.trim(line) == "" do
      []
    else
      parts = String.split(line, ",")
      build_roster_entry(csv_student_ids(parts, columns), parts, columns)
    end
  end

  # 学籍番号を持つ行だけをエントリ化する（教員行・空行は除外）
  defp build_roster_entry([], _parts, _columns), do: []

  defp build_roster_entry(student_ids, parts, columns) do
    [
      %{
        student_ids: student_ids,
        name: csv_field(parts, columns, :student_name),
        github: csv_field(parts, columns, :github_username),
        graduation_year: csv_field(parts, columns, :graduation_year),
        completion_year: csv_field(parts, columns, :completion_year),
        graduate_student_id: csv_field(parts, columns, :graduate_student_id)
      }
    ]
  end

  defp parse_csv_line_for_student(line, columns) do
    # 空行をスキップ
    if String.trim(line) == "" do
      []
    else
      parts = String.split(line, ",")
      student_ids = csv_student_ids(parts, columns)
      student_name = csv_field(parts, columns, :student_name)
      github_username = csv_field(parts, columns, :github_username)

      build_student_entries(student_ids, student_name, github_username)
    end
  end

  # 有効なデータのみをエントリ化する（学籍番号と氏名は必須）。大学院生は学部/院の
  # 両学籍番号でマッチできるよう、student_id ごとにエントリを展開する。
  defp build_student_entries(student_ids, student_name, github_username)
       when student_ids != [] and is_binary(student_name) and student_name != "" do
    Enum.map(student_ids, fn student_id ->
      %{
        "student_id" => student_id,
        "name" => student_name,
        "github_username" => github_username || ""
      }
    end)
  end

  defp build_student_entries(_student_ids, _student_name, _github_username), do: []

  @doc """
  リポジトリ名からリポジトリタイプを推論

  Issue #388: Updated to support new type classification
  - sotsuron-report: Thesis survey report repositories (*-sotsuron-report).
    Checked before sotsuron: the -sotsuron substring test would otherwise
    swallow these names
  - sotsuron: Undergraduate thesis repositories (*-sotsuron)
  - master: Master thesis repositories (*-master)
  - wr: Weekly report repositories (*-wr)
  - ise: ISE report repositories (*-ise)
  - other: All other repository types (posters, memos, conference papers, etc.)
  """
  def infer_repository_type(repo_name) do
    cond do
      String.contains?(repo_name, "-sotsuron-report") -> {:ok, "sotsuron-report"}
      String.contains?(repo_name, "-sotsuron") -> {:ok, "sotsuron"}
      String.contains?(repo_name, "-master") -> {:ok, "master"}
      String.contains?(repo_name, "-wr") -> {:ok, "wr"}
      String.contains?(repo_name, "-ise") -> {:ok, "ise"}
      # Everything else (thesis, latex, poster, wakate-ronbun, etc.) maps to "other"
      true -> {:ok, "other"}
    end
  end
end
