defmodule RegistryManager.Commands.InferStudentId do
  @moduledoc """
  Infer Student ID command implementation for registry-manager v4.

  このコマンドは、指定されたリポジトリの github_username を元に、
  CSVファイルから学生IDを検索し、registryに設定します。

  ## 使用例
  ```bash
  registry-manager infer-student-id 91rs044-wr
  registry-manager infer-student-id demouser-wr --dry-run
  ```

  ## 処理フロー
  1. 指定されたリポジトリのregistry情報を取得
  2. github_username を確認
  3. CSVファイルから該当する学生IDを検索
  4. 見つかった学生IDをregistryに設定（既存のstudent_idがない場合のみ）
  """

  alias RegistryManager.{GitHubAPI, Repository}

  @doc """
  infer-student-idコマンドを実行

  ## 引数
  - `args`: [repository_name]
  - `opts`: オプション（キーワードリスト）
  - `test_params`: テスト用パラメータ

  ## オプション
  - `:dry_run` - 実際の変更を行わないドライランモード
  - `:verbose` - 詳細な出力を表示

  ## テストパラメータ
  - `:repositories` - テスト用のリポジトリデータ
  - `:csv_data` - テスト用のCSVデータ
  """
  @spec run(list(String.t()), keyword(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, opts \\ [], test_params \\ []) do
    with {:ok, {repo_name, _parsed_opts}} <- parse_args(args),
         {:ok, repositories} <- get_repositories(test_params),
         {:ok, repo_data} <- get_repository_data(repositories, repo_name),
         :ok <- validate_repository_state(repo_name, repo_data),
         {:ok, github_username} <- extract_github_username(repo_name, repo_data),
         {:ok, student_id} <- find_student_id_from_csv(github_username, test_params) do
      if opts[:dry_run] do
        {:ok, "[DRY-RUN] Would set student_id '#{student_id}' for repository '#{repo_name}'"}
      else
        update_repository_with_student_id(repo_name, student_id, opts)
      end
    end
  end

  @doc """
  引数を解析

  ## 戻り値
  - `{repository_name, options}` - 正常な場合
  - `{:error, reason}` - エラーの場合
  """
  def parse_args(args) do
    case args do
      [] ->
        {:error, "Repository name is required"}

      [repo_name] ->
        {:ok, {repo_name, []}}

      _ ->
        {:error, "Too many arguments. Usage: infer-student-id <repository_name>"}
    end
  end

  # プライベート関数群

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

  defp get_repository_data(repositories, repo_name) do
    case Map.get(repositories, repo_name) do
      nil -> {:error, "Repository '#{repo_name}' not found in registry"}
      data -> {:ok, data}
    end
  end

  defp validate_repository_state(repo_name, repo_data) do
    case Map.get(repo_data, "student_id") do
      nil ->
        :ok

      existing_id ->
        {:error, "Repository '#{repo_name}' already has student_id '#{existing_id}' set"}
    end
  end

  defp extract_github_username(repo_name, repo_data) do
    case Map.get(repo_data, "github_username") do
      nil ->
        {:error, "Repository '#{repo_name}' does not have github_username set"}

      "" ->
        {:error, "Repository '#{repo_name}' does not have github_username set"}

      username ->
        {:ok, username}
    end
  end

  defp find_student_id_from_csv(github_username, test_params) do
    case Keyword.get(test_params, :csv_data) do
      nil ->
        # 実際のCSVファイルから読み込み
        find_student_id_from_actual_csv(github_username)

      test_csv_data ->
        # テスト用データから検索
        find_student_id_from_csv_data(github_username, test_csv_data)
    end
  end

  defp find_student_id_from_actual_csv(github_username) do
    # Repository.get_student_id_from_csv_by_github/1 を使用
    case Repository.get_student_id_from_csv_by_github(github_username) do
      {:ok, student_id} -> {:ok, student_id}
      {:error, _} -> {:error, "GitHub username '#{github_username}' not found in CSV file"}
    end
  end

  defp find_student_id_from_csv_data(github_username, csv_data) do
    # CSVデータの形式: [["氏名", "よみ", "学籍番号", "所属", "学年", "学科", "教員", "GitHub ID"], [...]]
    # GitHub IDは8列目（インデックス7）、学籍番号は3列目（インデックス2）

    # ヘッダー行をスキップして検索
    result =
      csv_data
      |> Enum.drop(1)
      |> Enum.find_value(&extract_student_id_from_csv_row(&1, github_username))

    case result do
      nil -> {:error, "GitHub username '#{github_username}' not found in CSV file"}
      student_id -> {:ok, student_id}
    end
  end

  defp extract_student_id_from_csv_row(row, target_github_username) do
    github_username = Enum.at(row, 7)
    student_id = Enum.at(row, 2)

    if github_username == target_github_username and valid_student_id?(student_id) do
      String.trim(student_id)
    end
  end

  defp valid_student_id?(student_id) do
    is_binary(student_id) and student_id != ""
  end

  defp update_repository_with_student_id(repo_name, student_id, opts) do
    # テストモードの場合は実際の更新をスキップ
    if Application.get_env(:registry_manager, :test_mode, false) do
      {:ok, "Student ID '#{student_id}' has been set for repository '#{repo_name}'"}
    else
      case Repository.update(repo_name, "student_id", student_id, opts) do
        {:ok, _} ->
          {:ok, "Student ID '#{student_id}' has been set for repository '#{repo_name}'"}

        {:error, reason} ->
          {:error, "Failed to update repository: #{reason}"}
      end
    end
  end
end
