defmodule RegistryManager.Test.TestDataStore do
  @moduledoc """
  Test data store for unit testing
  """

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{data: %{}, sha: "test-sha", commits: []} end, name: __MODULE__)
  end

  def set_data(data, sha \\ "test-sha") do
    Agent.update(__MODULE__, fn state ->
      %{state | data: data, sha: sha}
    end)
  end

  def get_data do
    Agent.get(__MODULE__, fn state ->
      {:ok, {state.data, state.sha}}
    end)
  end

  def update_data(new_data, current_sha, commit_message) do
    Agent.update(__MODULE__, fn state ->
      if state.sha == current_sha do
        new_sha = "sha-#{:erlang.unique_integer([:positive])}"

        commit = %{
          sha: new_sha,
          message: commit_message,
          data: new_data,
          timestamp: DateTime.utc_now()
        }

        %{
          data: new_data,
          sha: new_sha,
          commits: [commit | state.commits]
        }
      else
        state
      end
    end)

    {:ok, "Updated successfully"}
  end

  def get_commits do
    Agent.get(__MODULE__, fn state -> state.commits end)
  end

  def reset do
    Agent.update(__MODULE__, fn _state ->
      %{data: %{}, sha: "test-sha", commits: []}
    end)
  end
end
