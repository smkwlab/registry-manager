defmodule RegistryManager.Repository.DataStore do
  @moduledoc """
  Repository data persistence layer - GitHub API との統合を担当

  このモジュールはレジストリデータの永続化に関する外部依存（GitHub API）を管理します。
  ビジネスロジックは含まず、純粋にデータの読み書きのみを担当します。
  """

  alias RegistryManager.GitHubAPI

  @doc """
  レジストリデータを取得
  """
  def fetch_registry do
    GitHubAPI.get_repositories_json()
  end

  @doc """
  リポジトリエントリを保存
  """
  def save_entry(repo_name, entry_data, commit_message) do
    case fetch_registry() do
      {:ok, {current_data, sha}} ->
        updated_data = Map.put(current_data, repo_name, entry_data)
        GitHubAPI.update_repositories_json(updated_data, sha, commit_message)

      {:error, reason} ->
        {:error, "Failed to save entry for #{repo_name}: #{reason}"}
    end
  end

  @doc """
  リポジトリエントリを更新
  """
  def update_entry(repo_name, field, value, commit_message) do
    with {:ok, {current_data, sha}} <- fetch_registry(),
         {:ok, existing_entry} <- get_existing_entry(current_data, repo_name) do
      updated_entry =
        existing_entry
        |> Map.put(field, value)
        |> Map.put("registry_updated_at", DateTime.utc_now() |> DateTime.to_string())

      updated_data = Map.put(current_data, repo_name, updated_entry)
      GitHubAPI.update_repositories_json(updated_data, sha, commit_message)
    else
      {:error, reason} -> {:error, "Failed to update entry for #{repo_name}: #{reason}"}
    end
  end

  @doc """
  リポジトリエントリを削除
  """
  def delete_entry(repo_name, commit_message) do
    with {:ok, {current_data, sha}} <- fetch_registry(),
         {:ok, _existing_entry} <- get_existing_entry(current_data, repo_name) do
      updated_data = Map.delete(current_data, repo_name)
      GitHubAPI.update_repositories_json(updated_data, sha, commit_message)
    else
      {:error, reason} -> {:error, "Failed to delete entry for #{repo_name}: #{reason}"}
    end
  end

  @doc """
  特定のリポジトリエントリが存在するかチェック
  """
  def entry_exists?(repo_name) do
    case fetch_registry() do
      {:ok, {current_data, _sha}} ->
        Map.has_key?(current_data, repo_name)

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to check entry existence for #{repo_name}: #{inspect(reason)}")
        false
    end
  end

  @doc """
  レジストリ内の全エントリを取得
  """
  def get_all_entries do
    case fetch_registry() do
      {:ok, {current_data, _sha}} -> {:ok, current_data}
      error -> error
    end
  end

  @doc """
  全レジストリデータを一括保存
  """
  def save_all_entries(data, commit_message) do
    case fetch_registry() do
      {:ok, {_current_data, sha}} ->
        GitHubAPI.update_repositories_json(data, sha, commit_message)

      {:error, reason} ->
        {:error, "Failed to save all entries: #{reason}"}
    end
  end

  @doc """
  レジストリ全体を保存
  """
  def save_registry(data, sha, commit_message) do
    GitHubAPI.update_repositories_json(data, sha, commit_message)
  end

  # プライベート関数

  defp get_existing_entry(current_data, repo_name) do
    case Map.get(current_data, repo_name) do
      nil -> {:error, "Repository not found: #{repo_name}"}
      entry -> {:ok, entry}
    end
  end
end
