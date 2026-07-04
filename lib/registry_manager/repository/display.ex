defmodule RegistryManager.Repository.Display do
  @moduledoc """
  リポジトリ情報の表示とフォーマット機能
  """

  @doc """
  統計情報をフォーマット
  """
  def format_statistics(stats) do
    type_summary =
      stats.type
      |> Enum.map(fn {type, count} -> "      #{type}: #{count}" end)
      |> Enum.join("\n")

    """
    === リポジトリ統計 ===
    総リポジトリ数: #{stats.total}
    タイプ別:
    #{type_summary}
      保護設定済み: #{stats.protected}
    """
  end

  @doc """
  検証成功結果をフォーマット
  """
  def format_validation_success(stats) do
    """
    ✅ データ整合性検証完了

    === 検証結果 ===
    総エントリ数: #{stats.total_entries}
    有効エントリ数: #{stats.valid_entries}
    エラー: 0件

    すべてのデータが正常です。
    """
  end

  @doc """
  検証エラーをフォーマット
  """
  def format_validation_errors(errors) do
    error_list =
      errors
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {error, index} -> "  #{index}. #{error}" end)

    """
    ❌ データ整合性検証で問題が見つかりました

    === エラー詳細 (#{length(errors)}件) ===
    #{error_list}

    上記の問題を修正してください。
    """
  end

  @doc """
  リポジトリ一覧をフォーマット
  """
  def format_repository_list(formatted_list, filter) do
    if filter do
      "リポジトリ一覧 (フィルター: #{filter})\n#{formatted_list}"
    else
      "リポジトリ一覧\n#{formatted_list}"
    end
  end

  @doc """
  特定のリポジトリ情報をフォーマット
  """
  def format_repository_info(repo_name, repo_info) do
    case Jason.encode(repo_info, pretty: true) do
      {:ok, formatted_info} ->
        "リポジトリ状況: #{repo_name}\n#{formatted_info}"

      {:error, _reason} ->
        "リポジトリ状況: #{repo_name}\n[データ形式エラー]"
    end
  end
end
