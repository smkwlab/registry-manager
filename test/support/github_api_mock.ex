defmodule RegistryManager.Test.GitHubAPIMock do
  @moduledoc """
  GitHubAPI用のモックヘルパー
  テスト時に実際のGitHub APIを呼び出さないようにする
  """

  # Dynamic mock responses storage
  @doc """
  モックレスポンスを設定
  """
  def set_mock_response(function_name, response_fun) do
    ensure_agent_started()

    Agent.update(__MODULE__, fn state ->
      Map.put(state, function_name, response_fun)
    end)
  end

  defp get_mock_response(function_name, default_fun) do
    ensure_agent_started()

    try do
      Agent.get(__MODULE__, fn state ->
        Map.get(state, function_name, default_fun)
      end)
    rescue
      _ -> default_fun
    end
  end

  @doc """
  モックレスポンスをクリア
  """
  def clear_mock_responses do
    ensure_agent_started()
    Agent.update(__MODULE__, fn _state -> %{} end)
  end

  defp ensure_agent_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case Agent.start_link(fn -> %{} end, name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  @test_repositories_data %{
    "k21rs001-sotsuron" => %{
      "student_id" => "k21rs001",
      "repository_type" => "sotsuron",
      "created_at" => "2025-01-01T00:00:00Z",
      "registry_updated_at" => "2025-01-01T00:00:00Z",
      "protection_status" => "protected"
    },
    "k21rs002-wr" => %{
      "student_id" => "k21rs002",
      "repository_type" => "wr",
      "created_at" => "2025-01-02T00:00:00Z",
      "registry_updated_at" => "2025-01-02T00:00:00Z",
      "protection_status" => "not_protected"
    },
    "k21rs003-wr" => %{
      "student_id" => "k21rs003",
      "repository_type" => "wr",
      "created_at" => "2025-06-25T00:00:00Z",
      "registry_updated_at" => "2025-06-25T00:00:00Z",
      "protection_status" => "protected"
    }
  }

  @test_sha "abc123def456"

  @doc """
  テスト用リポジトリデータを取得
  """
  def get_repositories_json do
    default_fun = fn -> {:ok, {@test_repositories_data, @test_sha}} end
    response_fun = get_mock_response(:get_repositories_json, default_fun)
    response_fun.()
  end

  @doc """
  テスト用リポジトリデータ更新（常に成功）
  """
  def update_repositories_json(new_data, current_sha, commit_message) do
    default_fun = fn _, _, _ -> {:ok, "Repository updated successfully"} end
    response_fun = get_mock_response(:update_repositories_json, default_fun)
    response_fun.(new_data, current_sha, commit_message)
  end

  @doc """
  テスト用リポジトリ情報取得
  """
  def get_repository_info(repo_name) do
    default_fun = fn repo_name ->
      case repo_name do
        "smkwlab/k21rs001-sotsuron" ->
          {:ok,
           %{
             "owner" => %{"login" => "taro-yamada"},
             "created_at" => "2025-01-01T00:00:00Z"
           }}

        "smkwlab/k21rs002-ise" ->
          {:ok,
           %{
             "owner" => %{"login" => "hanako-suzuki"},
             "created_at" => "2025-01-01T00:00:00Z"
           }}

        "smkwlab/k21rs003-wr" ->
          {:ok,
           %{
             "owner" => %{"login" => "unknown-user"},
             "created_at" => "2025-01-01T00:00:00Z"
           }}

        _ ->
          {:error, "Repository not found"}
      end
    end

    response_fun = get_mock_response(:get_repository_info, default_fun)
    response_fun.(repo_name)
  end

  @doc """
  テスト用リポジトリ活動時刻取得
  """
  def get_repository_activity(repo_name, opts \\ []) do
    default_fun = fn repo_name, _opts ->
      cond do
        String.contains?(repo_name, "nonexistent") ->
          {:error, "Repository not found"}

        String.contains?(repo_name, "error") ->
          {:error, "GitHub API error"}

        repo_name == "smkwlab/thesis-student-registry" ->
          {:ok, "2025-07-02T06:30:00Z"}

        String.starts_with?(repo_name, "k") ->
          # Mock student repository activity
          {:ok, "2025-07-01T12:00:00Z"}

        true ->
          {:ok, "2025-06-30T09:00:00Z"}
      end
    end

    response_fun = get_mock_response(:get_repository_activity, default_fun)
    response_fun.(repo_name, opts)
  end

  @doc """
  テスト用実際の開発者取得
  """
  def get_actual_developer(repo_name, opts \\ []) do
    default_fun = fn repo_name, _opts ->
      case repo_name do
        "smkwlab/sampleuser-wr" ->
          {:ok, "k91rs012"}

        "smkwlab/k21rs001-sotsuron" ->
          {:ok, "taro-yamada"}

        "smkwlab/k21rs002-ise" ->
          {:ok, "hanako-suzuki"}

        _ ->
          {:error, "No commits found"}
      end
    end

    response_fun = get_mock_response(:get_actual_developer, default_fun)
    response_fun.(repo_name, opts)
  end

  @doc """
  テスト用データを使用するようにアプリケーション設定を変更
  """
  def setup_mock do
    # GitHubAPIモジュールの関数をこのモックに置き換える
    # Elixirのモックライブラリ（Mox）を使用するのが理想的だが、
    # 簡単な実装として環境変数でテストモードを判定
    Application.put_env(:registry_manager, :test_mode, true)
  end

  @doc """
  モック設定をクリア
  """
  def cleanup_mock do
    Application.delete_env(:registry_manager, :test_mode)

    # Check if agent is alive before stopping
    if Process.whereis(__MODULE__) do
      try do
        Agent.stop(__MODULE__)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  @doc """
  モックレスポンスをリセット
  """
  def reset_mock_responses do
    ensure_agent_started()
    Agent.update(__MODULE__, fn _state -> %{} end)
  end
end
