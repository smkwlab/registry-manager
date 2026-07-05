defmodule RegistryManager do
  @moduledoc """
  Registry Manager

  GitHub API経由で学生リポジトリレジストリ（設定 registry_repo で指定した
  データリポジトリの data/registry.json、旧名 data/repositories.json）を
  管理するツール。
  """

  alias RegistryManager.{GitHubAPI, Repository}

  @doc """
  リポジトリ情報を追加（新形式 - stage と status なし）
  """
  defdelegate add(repo_name, student_id, repo_type, opts \\ []), to: Repository

  @doc """
  リポジトリ情報を更新
  """
  defdelegate update(repo_name, field, value, opts \\ []), to: Repository

  @doc """
  リポジトリ情報をレジストリから削除
  """
  defdelegate remove(repo_name, opts \\ []), to: Repository

  @doc """
  ブランチ保護設定完了をマーク
  """
  defdelegate mark_protected(repo_name, opts \\ []), to: Repository

  @doc """
  リポジトリ状況を表示
  """
  defdelegate show_status(repo_name, opts \\ []), to: Repository

  @doc """
  リポジトリ一覧を表示
  """
  defdelegate list_repositories(filter, opts \\ []), to: Repository

  @doc """
  GitHub APIから現在のリポジトリ情報を取得
  """
  defdelegate get_repositories_json(), to: GitHubAPI
end
