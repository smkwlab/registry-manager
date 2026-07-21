defmodule RegistryManager.Validation do
  @moduledoc """
  学生ID形式の検証とデータ整合性チェック機能を提供
  """

  @doc """
  学生IDの形式を検証する

  ## 有効な形式
  - 学部生: k##rs### または k##jk### (例: k21rs001, k92jk123)
  - 大学院生: k##gjk## (例: k91gjk01, k92gjk15)

  ## Examples
      iex> RegistryManager.Validation.validate_student_id("k21rs001")
      :ok

      iex> RegistryManager.Validation.validate_student_id("k21rs01")
      {:error, "不正な学生ID形式: k21rs01 (expected: k##rs###, k##jk###, または k##gjk##)"}

      iex> RegistryManager.Validation.validate_student_id("k91gjk01")
      :ok
  """
  def validate_student_id(student_id) when is_binary(student_id) do
    cond do
      # 学部生パターン: k##rs### または k##jk###
      Regex.match?(~r/^k\d{2}(rs|jk)\d{3}$/, student_id) ->
        :ok

      # 大学院生パターン: k##gjk##
      Regex.match?(~r/^k\d{2}gjk\d{2}$/, student_id) ->
        :ok

      true ->
        {:error, "不正な学生ID形式: #{student_id} (expected: k##rs###, k##jk###, または k##gjk##)"}
    end
  end

  def validate_student_id(_), do: {:error, "学生IDは文字列である必要があります"}

  @doc """
  リポジトリエントリの新しいデータ構造を検証する

  v4の新しい構造では:
  - repository_created_at: GitHub リポジトリの作成日時（必須）
  - registry_created_at: レジストリへの登録日時（必須）
  - registry_updated_at: レジストリ内での最終更新日時（必須）
  - stage フィールドは廃止
  - status フィールドは廃止

  ## Examples
      iex> entry = %{
      ...>   "student_id" => "k21rs001",
      ...>   "repository_type" => "sotsuron",
      ...>   "repository_created_at" => "2025-07-02T10:00:00Z",
      ...>   "registry_created_at" => "2025-07-02T10:00:00Z",
      ...>   "registry_updated_at" => "2025-07-02T10:00:00Z"
      ...> }
      iex> RegistryManager.Validation.validate_repository_entry(entry)
      :ok
  """
  def validate_repository_entry(entry) when is_map(entry) do
    with :ok <- validate_required_fields_v4(entry),
         :ok <- validate_no_deprecated_fields(entry),
         :ok <- validate_timestamp_fields_v4(entry) do
      :ok
    end
  end

  defp validate_required_fields_v4(entry) do
    required_fields = [
      "student_id",
      "repository_type",
      "repository_created_at",
      "registry_created_at",
      "registry_updated_at"
    ]

    missing_fields =
      Enum.filter(required_fields, fn field ->
        not Map.has_key?(entry, field) or entry[field] == nil or entry[field] == ""
      end)

    if Enum.empty?(missing_fields) do
      :ok
    else
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  defp validate_no_deprecated_fields(entry) do
    deprecated_fields = ["stage", "status"]

    found_deprecated =
      Enum.filter(deprecated_fields, fn field ->
        Map.has_key?(entry, field)
      end)

    if Enum.empty?(found_deprecated) do
      :ok
    else
      {:error,
       "Deprecated fields found: #{Enum.join(found_deprecated, ", ")}. These fields are no longer supported."}
    end
  end

  defp validate_timestamp_fields_v4(entry) do
    timestamp_fields = [
      "repository_created_at",
      "registry_created_at",
      "registry_updated_at"
    ]

    invalid_fields =
      Enum.filter(timestamp_fields, fn field ->
        case Map.get(entry, field) do
          nil ->
            true

          value when is_binary(value) ->
            not valid_iso8601_timestamp?(value)

          _ ->
            true
        end
      end)

    if Enum.empty?(invalid_fields) do
      :ok
    else
      {:error,
       "Invalid timestamp format in fields: #{Enum.join(invalid_fields, ", ")}. Expected ISO8601 format (e.g., 2025-07-02T10:00:00Z)"}
    end
  end

  defp valid_iso8601_timestamp?(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, _datetime, _offset} -> true
      {:error, _reason} -> false
    end
  end

  @doc """
  既存のエントリが移行を必要とするかチェックする
  """
  def check_migration_needed(entry) when is_map(entry) do
    deprecated_fields = ["stage", "status"]

    found_deprecated =
      Enum.filter(deprecated_fields, fn field ->
        Map.has_key?(entry, field)
      end)

    if Enum.empty?(found_deprecated) do
      :no_migration_needed
    else
      {:migration_needed, found_deprecated}
    end
  end

  @doc """
  リポジトリ名の整合性を検証する

  ## Examples
      iex> RegistryManager.Validation.validate_repository_name("k21rs001-sotsuron", "k21rs001")
      :ok

      iex> RegistryManager.Validation.validate_repository_name("k21rs002-sotsuron", "k21rs001")
      {:error, "リポジトリ名と学生IDが一致しません: k21rs002-sotsuron should start with k21rs001-"}
  """
  def validate_repository_name(repo_name, student_id) do
    # Remove org prefix if present (e.g., "myorg/" from "myorg/k21rs001-sotsuron")
    base_repo_name = String.replace(repo_name, ~r{^[^/]+/}, "")
    expected_prefix = "#{student_id}-"

    if String.starts_with?(base_repo_name, expected_prefix) do
      :ok
    else
      {:error, "リポジトリ名と学生IDが一致しません: #{repo_name} should start with #{expected_prefix}"}
    end
  end

  @doc """
  リポジトリタイプの有効性を検証する

  ## Examples
      iex> RegistryManager.Validation.validate_repository_type("sotsuron")
      :ok

      iex> RegistryManager.Validation.validate_repository_type("invalid")
      {:error, "不正なリポジトリタイプ: invalid (valid: sotsuron, master, wr, ise, ise-report, latex, poster, sotsuron-report, other)"}
  """
  def validate_repository_type(repo_type) do
    # thesis は repo 名 suffix・文書種別・フィルタ名のレイヤの語であり type ではない
    valid_types = [
      "sotsuron",
      "master",
      "wr",
      "ise",
      "ise-report",
      "latex",
      "poster",
      "sotsuron-report",
      "other"
    ]

    cond do
      repo_type in valid_types ->
        :ok

      repo_type == "thesis" ->
        {:error,
         "不正なリポジトリタイプ: thesis は repository_type ではありません" <>
           "（修論は master、latex-template 派生は latex を使用。valid: #{Enum.join(valid_types, ", ")}）"}

      true ->
        {:error, "不正なリポジトリタイプ: #{repo_type} (valid: #{Enum.join(valid_types, ", ")})"}
    end
  end

  # draft PR サイクルが常時有効なタイプ。latex は作成時オプトインのため含めない
  @review_flow_types ["sotsuron", "master", "ise", "ise-report", "poster"]

  @doc """
  リポジトリタイプ由来の review_flow 既定値を返す

  draft PR サイクルが常時有効なタイプ（sotsuron / master / ise / poster）は true、
  wr / other は false。latex は作成時オプトインのため既定は false で、
  明示指定（--review-flow）で上書きする。
  """
  def default_review_flow(repo_type), do: repo_type in @review_flow_types

  @doc """
  全レジストリデータの整合性を検証する

  repositoriesデータの各エントリに対して包括的な検証を実行します。

  ## Returns
  - `{:ok, stats}` - 検証成功時、統計情報を返す
  - `{:error, errors}` - 検証失敗時、エラーリストを返す
  """
  def validate_all_data(repositories) when is_map(repositories) do
    results =
      repositories
      |> Enum.map(fn {repo_name, data} ->
        validate_entry(repo_name, data)
      end)

    errors = results |> Enum.filter(&match?({:error, _}, &1)) |> Enum.map(&elem(&1, 1))
    successes = results |> Enum.count(&match?(:ok, &1))

    if Enum.empty?(errors) do
      stats = %{
        total_entries: map_size(repositories),
        valid_entries: successes,
        errors: []
      }

      {:ok, stats}
    else
      {:error, errors}
    end
  end

  defp validate_entry(repo_name, data) do
    with :ok <- validate_required_fields(data),
         :ok <- validate_student_id(data["student_id"]),
         :ok <- validate_repository_name(repo_name, data["student_id"]),
         :ok <- validate_repository_type(data["repository_type"]) do
      :ok
    else
      {:error, reason} -> {:error, "#{repo_name}: #{reason}"}
    end
  end

  defp validate_required_fields(data) do
    # 新しいデータ構造の必須フィールド（後方互換性も考慮）
    required_fields = ["student_id", "repository_type"]
    # created_at または registry_updated_at または updated_at のいずれかが必要
    timestamp_fields = ["created_at", "registry_updated_at", "updated_at"]

    missing_fields =
      required_fields
      |> Enum.filter(fn field -> is_nil(data[field]) or data[field] == "" end)

    has_timestamp =
      Enum.any?(timestamp_fields, fn field ->
        not (is_nil(data[field]) or data[field] == "")
      end)

    cond do
      not Enum.empty?(missing_fields) ->
        {:error, "必須フィールドが不足: #{Enum.join(missing_fields, ", ")}"}

      not has_timestamp ->
        {:error, "タイムスタンプフィールドが不足: #{Enum.join(timestamp_fields, " または ")} のいずれかが必要"}

      true ->
        :ok
    end
  end
end
