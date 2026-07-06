defmodule RegistryManager.Commands.PropagateWorkflow do
  @moduledoc """
  Propagate workflow updates through draft branches.

  This command ensures that workflow updates are properly merged through the
  draft branch hierarchy (main → 0th-draft → 1st-draft → ...) to prevent
  conflicts when students create PRs between draft branches.

  ## Usage

      registry-manager propagate-workflow <repo_name>
      registry-manager propagate-workflow --all --type thesis
      registry-manager propagate-workflow --all --type thesis --from-template

  ## Options

  - `--dry-run`: Show what would be done without making changes
  - `--all`: Process all registered repositories
  - `--type`: Filter repositories by type (wr, ise, sotsuron, master, thesis, latex, other)
  - `--from-template`: Apply workflow file updates from template repository before propagating
  - `--verbose`: Show detailed output

  ## Background

  When updating workflow files in student repositories, changes must be
  propagated through the branch hierarchy to maintain consistent merge history.
  If branches are updated out of order (e.g., directly from main to 4th-draft),
  subsequent PRs between draft branches may have conflicts.

  The `--from-template` option first compares workflow files between the
  template repository (e.g., sotsuron-template) and the target repository,
  applying any differences to the main branch before propagating through
  draft branches.

  See: latex-ecosystem/CLAUDE.md "Updating Workflow Files in Student Repositories"
  """

  alias RegistryManager.Config
  alias RegistryManager.GitHubAPI
  alias RegistryManager.GitHubAPI.Client

  require Logger

  @draft_branch_pattern ~r/^(\d+)(st|nd|rd|th)-draft$/

  @spec run(list(), keyword(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, opts, test_params \\ []) do
    with {:ok, validated_opts} <- validate_options(opts),
         {:ok, repositories} <- get_target_repositories(args, validated_opts, test_params),
         {:ok, results} <- process_repositories(repositories, validated_opts, test_params) do
      {:ok, format_results(results, validated_opts)}
    end
  end

  @doc """
  Validate command options
  """
  def validate_options(opts) do
    {:ok,
     [
       dry_run: opts[:dry_run] || false,
       all: opts[:all] || false,
       type: opts[:type],
       verbose: opts[:verbose] || false,
       from_template: opts[:from_template] || false
     ]}
  end

  @doc """
  Get template repository name for a given student repository
  """
  def get_template_repo(repo_name) do
    cond do
      String.ends_with?(repo_name, "-sotsuron") -> "sotsuron-template"
      String.ends_with?(repo_name, "-master") -> "sotsuron-template"
      true -> nil
    end
  end

  @doc """
  Get list of workflow files to propagate from template
  """
  def get_workflow_files do
    [
      ".github/workflows/prevent-draft-merge.yml"
    ]
  end

  @doc """
  Get target repositories based on args and options
  """
  def get_target_repositories(args, opts, test_params) do
    cond do
      # 単一リポジトリが指定された場合
      length(args) == 1 ->
        [repo_name] = args
        {:ok, [repo_name]}

      # --all オプションが指定された場合
      opts[:all] ->
        get_all_repositories(opts, test_params)

      # 引数がない場合はエラー
      true ->
        {:error, "Repository name required. Use --all to process all repositories."}
    end
  end

  defp get_all_repositories(opts, test_params) do
    if Keyword.has_key?(test_params, :repositories) do
      repos = test_params[:repositories]
      filtered = filter_by_type(repos, opts[:type])
      {:ok, Map.keys(filtered)}
    else
      case GitHubAPI.get_repositories_json() do
        {:ok, {repos, _sha}} ->
          filtered = filter_by_type(repos, opts[:type])
          {:ok, Map.keys(filtered)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp filter_by_type(repos, nil), do: repos

  defp filter_by_type(repos, "thesis") do
    Enum.filter(repos, fn {_name, data} ->
      type = Map.get(data, "repository_type")
      type == "sotsuron" or type == "master"
    end)
    |> Enum.into(%{})
  end

  defp filter_by_type(repos, type) do
    Enum.filter(repos, fn {_name, data} ->
      Map.get(data, "repository_type") == type
    end)
    |> Enum.into(%{})
  end

  @doc """
  Process all target repositories
  """
  def process_repositories(repositories, opts, test_params) do
    results =
      Enum.map(repositories, fn repo_name ->
        result = process_single_repository(repo_name, opts, test_params)
        {repo_name, result}
      end)

    {:ok, results}
  end

  @doc """
  Process a single repository
  """
  def process_single_repository(repo_name, opts, test_params) do
    if opts[:from_template] do
      process_with_template(repo_name, opts, test_params)
    else
      process_branches_only(repo_name, opts, test_params)
    end
  end

  defp process_branches_only(repo_name, opts, test_params) do
    with {:ok, branches} <- get_draft_branches(repo_name, test_params),
         {:ok, sorted_branches} <- sort_draft_branches(branches),
         {:ok, issues} <- check_branch_hierarchy(repo_name, sorted_branches, test_params) do
      if Enum.empty?(issues) do
        {:ok, :no_action_needed}
      else
        if opts[:dry_run] do
          {:ok, {:dry_run, issues}}
        else
          propagate_changes(repo_name, issues, opts, test_params)
        end
      end
    end
  end

  defp process_with_template(repo_name, opts, test_params) do
    with {:ok, template_updates} <- check_template_updates(repo_name, test_params),
         {:ok, branches} <- get_draft_branches(repo_name, test_params),
         {:ok, sorted_branches} <- sort_draft_branches(branches),
         {:ok, branch_issues} <- check_branch_hierarchy(repo_name, sorted_branches, test_params) do
      has_template_updates = not Enum.empty?(template_updates)
      has_branch_issues = not Enum.empty?(branch_issues)

      cond do
        not has_template_updates and not has_branch_issues ->
          {:ok, :no_action_needed}

        opts[:dry_run] ->
          {:ok, {:dry_run, %{template_updates: template_updates, branch_issues: branch_issues}}}

        true ->
          apply_template_and_propagate(
            repo_name,
            template_updates,
            branch_issues,
            opts,
            test_params
          )
      end
    end
  end

  defp check_template_updates(repo_name, test_params) do
    if Keyword.has_key?(test_params, :template_files) and
         Keyword.has_key?(test_params, :current_files) do
      template_files = test_params[:template_files]
      current_files = Map.get(test_params[:current_files], repo_name, %{})

      updates =
        Enum.filter(get_workflow_files(), fn file ->
          template_content = Map.get(template_files, file)
          current_content = Map.get(current_files, file)
          template_content != nil and template_content != current_content
        end)

      {:ok, updates}
    else
      check_template_updates_from_api(repo_name)
    end
  end

  defp check_template_updates_from_api(repo_name) do
    template_repo = get_template_repo(repo_name)

    if template_repo do
      config = Config.load_config()

      result =
        Enum.reduce_while(get_workflow_files(), {:ok, []}, fn file, acc ->
          check_single_workflow_file(config, template_repo, repo_name, file, acc)
        end)

      case result do
        {:ok, updates} -> {:ok, Enum.reverse(updates)}
        {:error, _} = error -> error
      end
    else
      {:ok, []}
    end
  end

  defp check_single_workflow_file(config, template_repo, repo_name, file, {:ok, acc}) do
    case {get_file_content(config.github_org, template_repo, file, "main"),
          get_file_content(config.github_org, repo_name, file, "main")} do
      # Both files exist and are different - needs update
      {{:ok, template_content}, {:ok, current_content}}
      when template_content != current_content ->
        {:cont, {:ok, [file | acc]}}

      # Both files exist and are the same - no update needed
      {{:ok, _template_content}, {:ok, _current_content}} ->
        {:cont, {:ok, acc}}

      # Template exists but target file is missing (404) - needs update
      {{:ok, _template_content}, {:error, :not_found}} ->
        {:cont, {:ok, [file | acc]}}

      # Template doesn't exist - skip this file
      {{:error, :not_found}, _} ->
        {:cont, {:ok, acc}}

      # Other errors (network, auth, etc.) - propagate error
      {{:error, reason}, _} ->
        {:halt, {:error, "Failed to get template file #{file}: #{reason}"}}

      {_, {:error, reason}} ->
        {:halt, {:error, "Failed to get target file #{file}: #{reason}"}}
    end
  end

  defp get_file_content(org, repo, path, ref) do
    url = "https://api.github.com/repos/#{org}/#{repo}/contents/#{path}?ref=#{ref}"

    case Client.get_github_token() do
      {:ok, token} -> request_file_content(url, path, token)
      {:error, reason} -> {:error, "GitHub auth failed: #{reason}"}
    end
  end

  defp request_file_content(url, path, token) do
    case Client.send_request(:get, url, token: token) do
      {:ok, response} ->
        decode_file_content(response, path)

      {:error, message} when is_binary(message) ->
        if String.contains?(message, "(404)") do
          {:error, :not_found}
        else
          {:error, message}
        end
    end
  end

  defp decode_file_content(response, path) do
    content = Map.get(response, "content", "")

    case Base.decode64(String.replace(content, "\n", "")) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "Invalid Base64 content in #{path}"}
    end
  end

  defp apply_template_and_propagate(repo_name, template_updates, branch_issues, opts, test_params) do
    if Keyword.has_key?(test_params, :mock_git) do
      # Test mode
      {:ok,
       {:applied_and_propagated,
        %{template_files: length(template_updates), branches: length(branch_issues)}}}
    else
      apply_template_and_propagate_with_git(repo_name, template_updates, branch_issues, opts)
    end
  end

  defp apply_template_and_propagate_with_git(repo_name, template_updates, _branch_issues, opts) do
    config = Config.load_config()
    full_repo_name = "#{config.github_org}/#{repo_name}"
    template_repo = get_template_repo(repo_name)

    tmp_dir = System.tmp_dir!()
    work_dir = Path.join(tmp_dir, "propagate-#{repo_name}-#{:erlang.system_time(:millisecond)}")

    try do
      case run_git_command([
             "clone",
             "--quiet",
             "git@github.com:#{full_repo_name}.git",
             work_dir
           ]) do
        {:ok, _} ->
          # Step 1: Apply template updates to main branch
          template_count =
            if Enum.empty?(template_updates) do
              0
            else
              apply_template_files(
                work_dir,
                config.github_org,
                template_repo,
                template_updates,
                opts
              )
            end

          # Step 2: Propagate through ALL draft branches in sequence
          # This ensures changes flow through the entire branch hierarchy
          branch_count = propagate_through_all_branches(work_dir, opts)

          {:ok,
           {:applied_and_propagated, %{template_files: template_count, branches: branch_count}}}

        {:error, reason} ->
          {:error, "Failed to clone: #{reason}"}
      end
    after
      File.rm_rf(work_dir)
    end
  end

  defp apply_template_files(work_dir, org, template_repo, files, opts) do
    verbose = opts[:verbose]

    # Checkout main branch
    case run_git_command(["checkout", "main"], work_dir) do
      {:ok, _} ->
        copy_and_commit_template_files(work_dir, org, template_repo, files, opts)

      {:error, reason} ->
        if verbose do
          Logger.warning("⚠️ Failed to checkout main: #{reason}")
        end

        0
    end
  end

  defp copy_and_commit_template_files(work_dir, org, template_repo, files, opts) do
    verbose = opts[:verbose]

    # Copy each file from template, tracking successes
    results =
      Enum.map(files, fn file ->
        copy_template_file(work_dir, org, template_repo, file, verbose)
      end)

    success_count = Enum.count(results, fn r -> match?({:ok, _}, r) end)

    if success_count > 0 do
      commit_updated_files(work_dir, results, success_count, verbose)
    else
      0
    end
  end

  defp copy_template_file(work_dir, org, template_repo, file, verbose) do
    with {:ok, content} <- get_file_content(org, template_repo, file, "main"),
         file_path = Path.join(work_dir, file),
         :ok <- File.mkdir_p(Path.dirname(file_path)),
         :ok <- File.write(file_path, content) do
      if verbose do
        Logger.info("📄 Updated #{file}")
      end

      {:ok, file}
    else
      {:error, reason} ->
        if verbose do
          Logger.warning("⚠️ Failed to update #{file}: #{inspect(reason)}")
        end

        {:error, file, reason}
    end
  end

  defp commit_updated_files(work_dir, results, success_count, verbose) do
    # Add only the files that were successfully updated
    updated_files =
      results
      |> Enum.filter(fn r -> match?({:ok, _}, r) end)
      |> Enum.map(fn {:ok, file} -> file end)

    Enum.each(updated_files, fn file ->
      run_git_command(["add", file], work_dir)
    end)

    # Commit and push
    with {:ok, _} <-
           run_git_command(
             ["commit", "-m", "Update workflow files from template"],
             work_dir
           ),
         {:ok, _} <- run_git_command(["push"], work_dir) do
      success_count
    else
      {:error, reason} ->
        if verbose do
          Logger.warning("⚠️ Failed to commit/push: #{reason}")
        end

        0
    end
  end

  defp propagate_through_all_branches(work_dir, opts) do
    verbose = opts[:verbose]

    # Fetch all remote branches
    fetch_all_branches(work_dir, verbose)

    # Get list of remote draft branches
    case run_git_command(["branch", "-r"], work_dir) do
      {:ok, output} ->
        output
        |> parse_draft_branches()
        |> merge_through_draft_chain(work_dir, opts)

      {:error, reason} ->
        if verbose do
          Logger.warning("⚠️ Failed to list branches: #{reason}")
        end

        0
    end
  end

  defp fetch_all_branches(work_dir, verbose) do
    case run_git_command(["fetch", "--all"], work_dir) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        if verbose do
          Logger.warning("⚠️ Failed to fetch: #{reason}")
        end
    end
  end

  defp parse_draft_branches(output) do
    draft_branches =
      output
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(fn branch ->
        String.starts_with?(branch, "origin/") and
          Regex.match?(@draft_branch_pattern, String.replace_prefix(branch, "origin/", ""))
      end)
      |> Enum.map(fn branch -> String.replace_prefix(branch, "origin/", "") end)

    # Sort draft branches (sort_draft_branches always returns {:ok, sorted})
    {:ok, sorted_branches} = sort_draft_branches(draft_branches)
    sorted_branches
  end

  defp merge_through_draft_chain(sorted_branches, work_dir, opts) do
    if Enum.empty?(sorted_branches) do
      0
    else
      # Build branch pairs: main → 0th, 0th → 1st, 1st → 2nd, ...
      pairs = build_branch_pairs(["main" | sorted_branches])

      # Merge through the chain
      results =
        Enum.map(pairs, fn {lower, upper} ->
          merge_branch_pair(work_dir, lower, upper, opts)
        end)

      Enum.count(results, fn r -> r == :ok end)
    end
  end

  defp merge_branch_pair(work_dir, lower, upper, opts) do
    result = merge_branch(work_dir, lower, upper, opts)

    if opts[:verbose] and result == :ok do
      Logger.info("✅ Merged #{lower} into #{upper}")
    end

    result
  end

  @doc """
  Get draft branches from a repository
  """
  def get_draft_branches(repo_name, test_params) do
    if Keyword.has_key?(test_params, :branches) do
      branches = Map.get(test_params[:branches], repo_name, [])
      {:ok, branches}
    else
      get_draft_branches_from_api(repo_name)
    end
  end

  defp get_draft_branches_from_api(repo_name) do
    config = Config.load_config()
    full_repo_name = "#{config.github_org}/#{repo_name}"
    url = "https://api.github.com/repos/#{full_repo_name}/branches?per_page=100"

    with {:ok, token} <- Client.get_github_token(),
         {:ok, response} <- Client.send_request(:get, url, token: token) do
      branches =
        response
        |> Enum.map(fn branch -> Map.get(branch, "name") end)
        |> Enum.filter(fn name -> Regex.match?(@draft_branch_pattern, name) end)

      {:ok, branches}
    end
  end

  @doc """
  Sort draft branches by their numeric prefix
  """
  def sort_draft_branches(branches) do
    sorted =
      branches
      |> Enum.map(fn branch ->
        case Regex.run(@draft_branch_pattern, branch) do
          [_, num, _suffix] -> {String.to_integer(num), branch}
          _ -> {999, branch}
        end
      end)
      |> Enum.sort_by(fn {num, _branch} -> num end)
      |> Enum.map(fn {_num, branch} -> branch end)

    {:ok, sorted}
  end

  @doc """
  Check if each branch contains all commits from the previous branch
  """
  def check_branch_hierarchy(repo_name, sorted_branches, test_params) do
    if Keyword.has_key?(test_params, :compare_results) do
      issues = Map.get(test_params[:compare_results], repo_name, [])
      {:ok, issues}
    else
      check_branch_hierarchy_from_api(repo_name, sorted_branches)
    end
  end

  defp check_branch_hierarchy_from_api(repo_name, sorted_branches) do
    config = Config.load_config()
    full_repo_name = "#{config.github_org}/#{repo_name}"

    # Build list of branch pairs to check: main → 0th, 0th → 1st, 1st → 2nd, ...
    pairs = build_branch_pairs(["main" | sorted_branches])

    # Single pass: filter and collect results together to avoid duplicate API calls
    issues =
      pairs
      |> Enum.flat_map(fn {lower, upper} ->
        case compare_branches(full_repo_name, lower, upper) do
          {:ok, ahead_by} when ahead_by > 0 -> [{lower, upper, ahead_by}]
          _ -> []
        end
      end)

    {:ok, issues}
  end

  defp build_branch_pairs([_single]), do: []

  defp build_branch_pairs([first | rest]) do
    case rest do
      [second | _] -> [{first, second} | build_branch_pairs(rest)]
      [] -> []
    end
  end

  defp compare_branches(full_repo_name, lower, upper) do
    # Check how many commits in lower are not in upper
    url = "https://api.github.com/repos/#{full_repo_name}/compare/#{upper}...#{lower}"

    with {:ok, token} <- Client.get_github_token(),
         {:ok, response} <- Client.send_request(:get, url, token: token) do
      ahead_by = Map.get(response, "ahead_by", 0)
      {:ok, ahead_by}
    end
  end

  @doc """
  Propagate changes by merging lower branches into upper branches
  """
  def propagate_changes(repo_name, issues, opts, test_params) do
    if Keyword.has_key?(test_params, :mock_git) do
      # Test mode: return success without actual git operations
      {:ok, {:propagated, length(issues)}}
    else
      propagate_changes_with_git(repo_name, issues, opts)
    end
  end

  defp propagate_changes_with_git(repo_name, _issues, opts) do
    config = Config.load_config()
    full_repo_name = "#{config.github_org}/#{repo_name}"

    # Create temp directory
    tmp_dir = System.tmp_dir!()
    work_dir = Path.join(tmp_dir, "propagate-#{repo_name}-#{:erlang.system_time(:millisecond)}")

    try do
      # Clone repository
      case run_git_command(["clone", "--quiet", "git@github.com:#{full_repo_name}.git", work_dir]) do
        {:ok, _} ->
          # Propagate through ALL draft branches in sequence
          # This ensures changes flow through the entire branch hierarchy
          success_count = propagate_through_all_branches(work_dir, opts)
          {:ok, {:propagated, success_count}}

        {:error, reason} ->
          {:error, "Failed to clone: #{reason}"}
      end
    after
      # Cleanup
      File.rm_rf(work_dir)
    end
  end

  defp merge_branch(work_dir, lower, upper, opts) do
    verbose = opts[:verbose]

    with {:ok, _} <- run_git_command(["checkout", upper], work_dir),
         {:ok, _} <- run_git_command(["fetch", "origin", lower], work_dir),
         {:ok, _} <-
           run_git_command(
             ["merge", "origin/#{lower}", "-m", "Merge #{lower} to reconcile workflow history"],
             work_dir
           ),
         {:ok, _} <- run_git_command(["push"], work_dir) do
      if verbose do
        Logger.info("✅ Merged #{lower} into #{upper}")
      end

      :ok
    else
      {:error, reason} ->
        if verbose do
          Logger.warning("❌ Failed to merge #{lower} into #{upper}: #{reason}")
        end

        {:error, reason}
    end
  end

  defp run_git_command(args, cwd \\ nil) do
    opts =
      if cwd do
        [cd: cwd, stderr_to_stdout: true]
      else
        [stderr_to_stdout: true]
      end

    case System.cmd("git", args, opts) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end

  @doc """
  Format results for output
  """
  def format_results(results, opts) do
    dry_run = opts[:dry_run]

    lines =
      Enum.map(results, fn {repo_name, result} ->
        format_single_result(repo_name, result, dry_run)
      end)

    Enum.join(lines, "\n")
  end

  defp format_single_result(repo_name, {:ok, :no_action_needed}, _dry_run) do
    "✅ #{repo_name}: All branches OK"
  end

  defp format_single_result(repo_name, {:ok, {:dry_run, issues}}, _dry_run)
       when is_list(issues) do
    issue_lines =
      Enum.map(issues, fn {lower, upper, ahead_by} ->
        "   - #{upper} is missing #{ahead_by} commits from #{lower}"
      end)

    "📋 #{repo_name}: Would merge:\n" <> Enum.join(issue_lines, "\n")
  end

  defp format_single_result(
         repo_name,
         {:ok, {:dry_run, %{template_updates: updates, branch_issues: issues}}},
         _dry_run
       ) do
    lines = []

    lines =
      if Enum.empty?(updates) do
        lines
      else
        file_list = Enum.map(updates, fn f -> "   - #{Path.basename(f)}" end)
        lines ++ ["📄 Would update from template:"] ++ file_list
      end

    lines =
      if Enum.empty?(issues) do
        lines
      else
        issue_list =
          Enum.map(issues, fn {lower, upper, ahead_by} ->
            "   - #{upper} is missing #{ahead_by} commits from #{lower}"
          end)

        lines ++ ["📋 Would merge:"] ++ issue_list
      end

    "📋 #{repo_name}:\n" <> Enum.join(lines, "\n")
  end

  defp format_single_result(repo_name, {:ok, {:propagated, count}}, _dry_run) do
    "✅ #{repo_name}: Propagated #{count} branch(es)"
  end

  defp format_single_result(
         repo_name,
         {:ok, {:applied_and_propagated, %{template_files: files, branches: branches}}},
         _dry_run
       ) do
    "✅ #{repo_name}: Applied #{files} file(s), propagated to #{branches} branch(es)"
  end

  defp format_single_result(repo_name, {:error, reason}, _dry_run) do
    "❌ #{repo_name}: Error - #{reason}"
  end
end
