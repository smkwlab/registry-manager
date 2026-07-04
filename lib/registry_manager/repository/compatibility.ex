defmodule RegistryManager.Repository.Compatibility do
  @moduledoc """
  GitHub username フィールドの後方互換性を提供するモジュール

  単一文字列と配列の両方の形式をサポートし、
  既存のコードとの互換性を保ちながら複数オーナー機能を実現します。
  """

  @doc """
  github_username フィールドを正規化して配列形式に変換

  ## Examples

      iex> normalize_github_username("user1")
      ["user1"]
      
      iex> normalize_github_username(["user1", "user2"])
      ["user1", "user2"]
      
      iex> normalize_github_username(nil)
      []
      
      iex> normalize_github_username("")
      []
  """
  @spec normalize_github_username(any()) :: [String.t()]
  def normalize_github_username(value) when is_binary(value) do
    if String.trim(value) == "" do
      []
    else
      [value]
    end
  end

  def normalize_github_username(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> Enum.uniq()
  end

  def normalize_github_username(_), do: []

  @doc """
  リポジトリデータのgithub_usernameフィールドを正規化

  読み込み時に使用して、古い形式のデータを新しい形式に変換します。
  """
  @spec normalize_repository_data(map()) :: map()
  def normalize_repository_data(repo_data) when is_map(repo_data) do
    case Map.get(repo_data, "github_username") do
      nil ->
        repo_data

      value ->
        normalized = normalize_github_username(value)

        if normalized == [] do
          Map.delete(repo_data, "github_username")
        else
          Map.put(repo_data, "github_username", normalized)
        end
    end
  end

  def normalize_repository_data(data), do: data

  @doc """
  複数のリポジトリデータを一括で正規化
  """
  @spec normalize_repositories(map()) :: map()
  def normalize_repositories(repositories) when is_map(repositories) do
    repositories
    |> Enum.map(fn {repo_name, repo_data} ->
      {repo_name, normalize_repository_data(repo_data)}
    end)
    |> Enum.into(%{})
  end

  def normalize_repositories(data), do: data

  @doc """
  主要なGitHubユーザー名を取得（最初の要素）

  後方互換性のため、単一ユーザーを期待する既存コード用。
  """
  @spec get_primary_github_username(map()) :: String.t() | nil
  def get_primary_github_username(repo_data) when is_map(repo_data) do
    case Map.get(repo_data, "github_username") do
      nil -> nil
      [] -> nil
      [first | _] when is_binary(first) -> first
      username when is_binary(username) -> username
      _ -> nil
    end
  end

  def get_primary_github_username(_), do: nil

  @doc """
  すべてのGitHubユーザー名を取得

  複数オーナー対応のコード用。
  """
  @spec get_all_github_usernames(map()) :: [String.t()]
  def get_all_github_usernames(repo_data) when is_map(repo_data) do
    repo_data
    |> Map.get("github_username")
    |> normalize_github_username()
  end

  def get_all_github_usernames(_), do: []

  @doc """
  GitHubユーザー名の追加
  """
  @spec add_github_username(map(), String.t()) :: map()
  def add_github_username(repo_data, username) when is_map(repo_data) and is_binary(username) do
    username = String.trim(username)

    if username == "" do
      repo_data
    else
      current_users = get_all_github_usernames(repo_data)

      if username in current_users do
        repo_data
      else
        updated_users = current_users ++ [username]
        Map.put(repo_data, "github_username", updated_users)
      end
    end
  end

  def add_github_username(repo_data, _), do: repo_data

  @doc """
  GitHubユーザー名の削除
  """
  @spec remove_github_username(map(), String.t()) :: map()
  def remove_github_username(repo_data, username)
      when is_map(repo_data) and is_binary(username) do
    username = String.trim(username)
    current_users = get_all_github_usernames(repo_data)

    updated_users = Enum.filter(current_users, &(&1 != username))

    if updated_users == [] do
      Map.delete(repo_data, "github_username")
    else
      Map.put(repo_data, "github_username", updated_users)
    end
  end

  def remove_github_username(repo_data, _), do: repo_data

  @doc """
  GitHubユーザー名の設定（既存を上書き）
  """
  @spec set_github_usernames(map(), [String.t()]) :: map()
  def set_github_usernames(repo_data, usernames) when is_map(repo_data) and is_list(usernames) do
    normalized = normalize_github_username(usernames)

    if normalized == [] do
      Map.delete(repo_data, "github_username")
    else
      Map.put(repo_data, "github_username", normalized)
    end
  end

  def set_github_usernames(repo_data, _), do: repo_data
end
