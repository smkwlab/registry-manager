defmodule RegistryManager.Repository do
  @moduledoc """
  リポジトリ管理のビジネスロジック - 外部依存なし

  このモジュールはリポジトリ管理の核となるビジネスロジックを担当します。
  データ永続化は DataStore モジュールに委譲し、外部依存を完全に分離します。
  """

  alias RegistryManager.Repository.{DataStore, Display, ErrorHandler}
  alias RegistryManager.{Config, Validation}

  @doc """
  新しいリポジトリエントリを構築（ビジネスロジック）
  """
  def build_new_entry(student_id, repo_type, timestamp, github_username \\ nil) do
    base_entry = %{
      "student_id" => student_id,
      "repository_type" => repo_type,
      "created_at" => timestamp,
      "registry_updated_at" => timestamp
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

  defp parse_github_username_from_csv(content, target_student_id) do
    content
    |> String.split("\n")
    # Skip header
    |> Enum.drop(1)
    |> Enum.find_value(fn line ->
      case parse_csv_line_for_github(line, target_student_id) do
        {:ok, github_username} -> github_username
        :not_found -> nil
      end
    end)
    |> case do
      nil -> {:error, "Student not found in CSV"}
      github_username -> {:ok, github_username}
    end
  end

  defp parse_csv_line_for_github(line, target_student_id) do
    parts = String.split(line, ",")

    case parts do
      [_, _, student_id, _, _, _, _, github_username | _] ->
        clean_student_id = String.trim(student_id)
        clean_github_username = String.trim(github_username)

        # Normalize student ID format for comparison
        normalized_id = normalize_student_id_for_comparison(clean_student_id)
        normalized_target = normalize_student_id_for_comparison(target_student_id)

        if normalized_id == normalized_target and clean_github_username != "" do
          {:ok, clean_github_username}
        else
          :not_found
        end

      _ ->
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

        entry = build_new_entry(student_id, repo_type, timestamp, github_username)

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
    if opts[:dry_run] do
      {:ok, "[DRY-RUN] リポジトリ情報を更新: #{repo_name} (#{field} = #{value})"}
    else
      perform_update(repo_name, field, value)
    end
  end

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
  """
  def build_github_deletion_command(repo_name) do
    "gh repo delete #{Config.load_config().github_org}/#{repo_name}"
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
      github_command = build_github_deletion_command(repo_name)
      message = "#{base_message}\n[DRY-RUN] GitHubリポジトリ削除コマンド: #{github_command}"
      {:ok, message}
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
      github_command = build_github_deletion_command(repo_name)

      message =
        "Registry updated successfully. To delete the GitHub repository, run:\n#{github_command}"

      {:ok, message}
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
        repo_info["status"] == filter or repo_info["repository_type"] == filter
      end)
      |> Enum.into(%{})
    else
      current_data
    end
  end

  @doc """
  全データの整合性を検証
  """
  def validate_all_data(opts \\ []) do
    if opts[:dry_run] do
      {:ok, "[DRY-RUN] データ整合性検証をスキップ"}
    else
      case DataStore.get_all_entries() do
        {:ok, current_data} ->
          ErrorHandler.handle_validation_result(Validation.validate_all_data(current_data))

        {:error, reason} ->
          ErrorHandler.handle_github_api_error({:error, reason})
      end
    end
  end

  # 推論関連のプライベート関数

  defp infer_repository_data(repo_name, opts) do
    full_repo_name = ensure_full_repo_name(repo_name)

    with {:ok, repo_info} <- RegistryManager.GitHubAPI.get_repository_info(full_repo_name),
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

  defp ensure_full_repo_name(repo_name) do
    if String.contains?(repo_name, "/") do
      repo_name
    else
      "#{Config.load_config().github_org}/#{repo_name}"
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
    full_repo_name = ensure_full_repo_name(repo_name)

    case RegistryManager.GitHubAPI.get_repository_info(full_repo_name) do
      {:ok, repo_info} ->
        extract_github_username_from_repo_info(full_repo_name, repo_info, opts)

      {:error, _} ->
        log_verbose(opts, "Repository not accessible for GitHub username inference")
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
    content
    |> String.split("\n")
    # ヘッダーをスキップ
    |> Enum.drop(1)
    |> Enum.find_value(&parse_csv_line_for_username(&1, target_username))
    |> case do
      nil -> {:error, "GitHub username not found in CSV"}
      result -> result
    end
  end

  defp parse_csv_line_for_username(line, target_username) do
    # 空行はスキップ（従来の return_if_empty_line は常に nil を返し
    # 短絡が機能していなかった — Elixir 1.20 の型チェッカが検出）
    if String.trim(line) == "" do
      nil
    else
      parse_csv_parts_for_username(String.split(line, ","), target_username)
    end
  end

  defp parse_csv_parts_for_username(parts, target_username) when length(parts) >= 8 do
    student_id = Enum.at(parts, 2) |> String.trim()
    github_username = Enum.at(parts, 7) |> String.trim()

    if github_username == target_username and student_id != "" do
      {:ok, normalize_student_id_for_comparison(student_id)}
    end
  end

  defp parse_csv_parts_for_username(_parts, _target_username), do: nil

  @doc """
  CSVファイルから全学生データを読み込み、List コマンドで使用可能な形式に変換
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
    content
    |> String.split("\n")
    # ヘッダーをスキップ
    |> Enum.drop(1)
    |> Enum.map(&parse_csv_line_for_student/1)
    |> Enum.filter(& &1)
  end

  defp parse_csv_line_for_student(line) do
    # 空行をスキップ
    if String.trim(line) == "" do
      nil
    else
      parts = String.split(line, ",")
      parse_csv_parts_for_student(parts)
    end
  end

  defp parse_csv_parts_for_student(parts) do
    student_id = safe_get_csv_field(parts, 2)
    student_name = safe_get_csv_field(parts, 3)
    github_username = safe_get_csv_field(parts, 7)

    # 有効なデータのみを返す（学生IDと名前は必須）
    if student_id && student_name && student_id != "" && student_name != "" do
      %{
        "student_id" => normalize_student_id_for_comparison(student_id),
        "name" => student_name,
        "github_username" => github_username || ""
      }
    else
      nil
    end
  end

  # CSV フィールドを安全に取得するヘルパー関数
  defp safe_get_csv_field(parts, index) do
    if length(parts) > index do
      parts |> Enum.at(index) |> String.trim()
    else
      nil
    end
  end

  @doc """
  リポジトリ名からリポジトリタイプを推論

  Issue #388: Updated to support new type classification
  - sotsuron: Undergraduate thesis repositories (*-sotsuron)
  - master: Master thesis repositories (*-master)
  - wr: Weekly report repositories (*-wr)
  - ise: ISE report repositories (*-ise)
  - other: All other repository types (posters, memos, conference papers, etc.)
  """
  def infer_repository_type(repo_name) do
    cond do
      String.contains?(repo_name, "-sotsuron") -> {:ok, "sotsuron"}
      String.contains?(repo_name, "-master") -> {:ok, "master"}
      String.contains?(repo_name, "-wr") -> {:ok, "wr"}
      String.contains?(repo_name, "-ise") -> {:ok, "ise"}
      # Everything else (thesis, latex, poster, wakate-ronbun, etc.) maps to "other"
      true -> {:ok, "other"}
    end
  end
end
