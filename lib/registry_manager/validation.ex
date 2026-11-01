defmodule RegistryManager.Validation do
  @moduledoc """
  学生ID・リポジトリ名・リポジトリタイプの形式検証と、
  リポジトリタイプ由来の review_flow 既定値を提供する。

  エントリ単位の整合性検証（必須フィールド・タイムスタンプ・旧フィールドの
  再流入ガード）は `RegistryManager.Commands.Validate` が持つ。現行スキーマの
  定義をそこ 1 箇所に保つため、このモジュールには置かない（#98）。
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
end
