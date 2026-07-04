defmodule RegistryManager.Repository.ErrorHandler do
  @moduledoc """
  リポジトリ操作のエラーハンドリング機能
  """

  alias RegistryManager.Repository.Display

  @doc """
  検証結果を処理
  """
  def handle_validation_result({:ok, stats}) do
    output = Display.format_validation_success(stats)
    {:ok, output}
  end

  def handle_validation_result({:error, errors}) do
    output = Display.format_validation_errors(errors)
    {:error, output}
  end

  @doc """
  GitHub API エラーを処理
  """
  def handle_github_api_error({:error, reason}) do
    {:error, "リポジトリデータの取得に失敗: #{reason}"}
  end

  @doc """
  リポジトリが見つからない場合のエラー
  """
  def handle_repository_not_found(repo_name) do
    {:error, "Repository not found: #{repo_name}"}
  end
end
