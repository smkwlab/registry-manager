defmodule RegistryManager.Commands.Migrate do
  @moduledoc """
  Migration command implementation for upgrading registry data format

  Provides commands to migrate registry data from v1 format to v4 format,
  including dry-run capabilities and detailed reporting.
  """

  alias RegistryManager.Migration

  @doc """
  Execute migration command

  ## Arguments:
  - args: Command arguments (currently unused)
  - opts: Command options

  ## Options:
  - dry_run: boolean - Perform dry run without making changes (default: true)
  - verbose: boolean - Show detailed output

  ## Returns:
  - {:ok, message} on success
  - {:error, reason} on failure
  """
  def run(args, opts) do
    case args do
      [] ->
        # Default migration command
        execute_migration(opts)

      ["status"] ->
        # Show migration status
        show_migration_status(opts)

      ["dry-run"] ->
        # Force dry run
        execute_migration(Keyword.put(opts, :dry_run, true))

      ["execute"] ->
        # Force execution (disable dry run)
        execute_migration(Keyword.put(opts, :dry_run, false))

      _ ->
        {:error, "Invalid migrate command arguments. Usage: migrate [status|dry-run|execute]"}
    end
  end

  defp execute_migration(opts) do
    # Default to dry run unless explicitly disabled
    dry_run = Keyword.get(opts, :dry_run, true)
    verbose = Keyword.get(opts, :verbose, false)

    if verbose and dry_run do
      IO.puts("Running migration in dry-run mode...")
      IO.puts("Use 'migrate execute' to perform actual migration.")
      IO.puts("")
    end

    Migration.execute_migration(opts)
  end

  defp show_migration_status(opts) do
    verbose = Keyword.get(opts, :verbose, false)

    if verbose, do: IO.puts("Analyzing current registry format...")

    case RegistryManager.GitHubAPI.get_repositories_json() do
      {:ok, {registry_data, _sha}} ->
        {:ok, report} = Migration.dry_run_migration(registry_data)
        IO.puts(report)
        {:ok, "Migration status analysis completed"}

      {:error, reason} ->
        {:error, "Failed to fetch registry data: #{reason}"}
    end
  end
end
