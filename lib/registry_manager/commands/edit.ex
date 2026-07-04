defmodule RegistryManager.Commands.Edit do
  @moduledoc """
  Edit command implementation for registry-manager v4.

  Provides functionality to edit repository data, particularly GitHub usernames/owners.
  """

  alias RegistryManager.Repository.{Compatibility, DataStore}

  require Logger

  @doc """
  Runs the edit command with given arguments and options.

  ## Arguments
  - repo_name: The repository name to edit

  ## Options
  - `add_owner`: Add a GitHub username as an owner
  - `remove_owner`: Remove a GitHub username from owners
  - `set_owners`: Set the complete list of owners (comma-separated)

  ## Examples
      # Add an owner
      edit ["repo-name"], [add_owner: "username"]
      
      # Remove an owner
      edit ["repo-name"], [remove_owner: "username"]
      
      # Set multiple owners
      edit ["repo-name"], [set_owners: "user1,user2,user3"]
  """
  @spec run(list(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run([repo_name], opts) do
    with {:ok, action} <- validate_options(opts),
         {:ok, {current_data, sha}} <- DataStore.fetch_registry(),
         {:ok, repo_data} <- get_repository_data(current_data, repo_name),
         {:ok, updated_repo_data} <- apply_edit_action(repo_data, action),
         {:ok, commit_msg} <- build_commit_message(repo_name, action),
         {:ok, result} <-
           save_updated_data(current_data, repo_name, updated_repo_data, sha, commit_msg) do
      Logger.debug("Successfully saved registry update: #{result}")
      {:ok, format_success_message(repo_name, action)}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to edit repository: #{inspect(reason)}"}

      error ->
        {:error, "Unexpected error during edit operation: #{inspect(error)}"}
    end
  end

  def run([], _opts) do
    {:error, "Repository name is required"}
  end

  def run(_args, _opts) do
    {:error, "Invalid arguments. Usage: registry-manager edit <repo-name> [options]"}
  end

  defp validate_options(opts) do
    add_owner = Keyword.get(opts, :add_owner)
    remove_owner = Keyword.get(opts, :remove_owner)
    set_owners = Keyword.get(opts, :set_owners)

    case {add_owner, remove_owner, set_owners} do
      {nil, nil, nil} ->
        {:error, "No edit action specified. Use --add-owner, --remove-owner, or --set-owners"}

      {owner, nil, nil} when is_binary(owner) ->
        {:ok, {:add_owner, owner}}

      {nil, owner, nil} when is_binary(owner) ->
        {:ok, {:remove_owner, owner}}

      {nil, nil, owners} when is_binary(owners) ->
        {:ok, {:set_owners, parse_comma_separated(owners)}}

      _ ->
        {:error, "Only one edit action can be specified at a time"}
    end
  end

  defp get_repository_data(registry_data, repo_name) do
    case Map.get(registry_data, repo_name) do
      nil ->
        {:error, "Repository '#{repo_name}' not found in registry"}

      repo_data ->
        {:ok, repo_data}
    end
  end

  defp apply_edit_action(repo_data, {:add_owner, username}) do
    updated = Compatibility.add_github_username(repo_data, username)
    {:ok, updated}
  end

  defp apply_edit_action(repo_data, {:remove_owner, username}) do
    updated = Compatibility.remove_github_username(repo_data, username)
    {:ok, updated}
  end

  defp apply_edit_action(repo_data, {:set_owners, usernames}) do
    updated = Compatibility.set_github_usernames(repo_data, usernames)
    {:ok, updated}
  end

  defp save_updated_data(current_data, repo_name, updated_repo_data, sha, commit_msg) do
    # Update timestamp
    updated_repo_data =
      Map.put(
        updated_repo_data,
        "registry_updated_at",
        DateTime.utc_now() |> DateTime.to_iso8601()
      )

    # Update the full registry data
    updated_data = Map.put(current_data, repo_name, updated_repo_data)

    # Save to GitHub
    DataStore.save_registry(updated_data, sha, commit_msg)
  end

  defp build_commit_message(repo_name, action) do
    action_desc =
      case action do
        {:add_owner, username} -> "Add owner '#{username}'"
        {:remove_owner, username} -> "Remove owner '#{username}'"
        {:set_owners, usernames} -> "Set owners to: #{Enum.join(usernames, ", ")}"
      end

    message = "Update #{repo_name}: #{action_desc}"
    {:ok, message}
  end

  defp format_success_message(repo_name, action) do
    case action do
      {:add_owner, username} ->
        "Successfully added '#{username}' as owner of '#{repo_name}'"

      {:remove_owner, username} ->
        "Successfully removed '#{username}' from owners of '#{repo_name}'"

      {:set_owners, usernames} ->
        "Successfully set owners of '#{repo_name}' to: #{Enum.join(usernames, ", ")}"
    end
  end

  defp parse_comma_separated(string) do
    string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end
end
