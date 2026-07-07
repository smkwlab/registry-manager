defmodule RegistryManager.Commands.PropagateWorkflowTest do
  use ExUnit.Case, async: true

  alias RegistryManager.Commands.PropagateWorkflow

  # テストデータ
  @test_repositories %{
    "k21rs001-sotsuron" => %{
      "student_id" => "k21rs001",
      "repository_type" => "sotsuron",
      "created_at" => "2024-01-01 10:00:00 UTC"
    },
    "k21rs002-wr" => %{
      "student_id" => "k21rs002",
      "repository_type" => "wr",
      "created_at" => "2024-01-02 09:00:00 UTC"
    },
    "k94gjk01-master" => %{
      "student_id" => "k94gjk01",
      "repository_type" => "master",
      "created_at" => "2024-01-04 12:00:00 UTC"
    }
  }

  describe "validate_options/1" do
    test "returns default options when none specified" do
      {:ok, opts} = PropagateWorkflow.validate_options([])

      assert opts[:dry_run] == false
      assert opts[:all] == false
      assert opts[:type] == nil
      assert opts[:verbose] == false
    end

    test "parses dry_run option" do
      {:ok, opts} = PropagateWorkflow.validate_options(dry_run: true)
      assert opts[:dry_run] == true
    end

    test "parses all option" do
      {:ok, opts} = PropagateWorkflow.validate_options(all: true)
      assert opts[:all] == true
    end

    test "parses type option" do
      {:ok, opts} = PropagateWorkflow.validate_options(type: "sotsuron")
      assert opts[:type] == "sotsuron"
    end

    test "parses from_template option" do
      {:ok, opts} = PropagateWorkflow.validate_options(from_template: true)
      assert opts[:from_template] == true
    end

    test "from_template defaults to false" do
      {:ok, opts} = PropagateWorkflow.validate_options([])
      assert opts[:from_template] == false
    end
  end

  describe "get_target_repositories/3" do
    test "returns single repository when specified" do
      {:ok, repos} =
        PropagateWorkflow.get_target_repositories(
          ["k21rs001-sotsuron"],
          [all: false],
          repositories: @test_repositories
        )

      assert repos == ["k21rs001-sotsuron"]
    end

    test "returns all repositories when --all is specified" do
      {:ok, repos} =
        PropagateWorkflow.get_target_repositories(
          [],
          [all: true, type: nil],
          repositories: @test_repositories
        )

      assert length(repos) == 3
      assert "k21rs001-sotsuron" in repos
      assert "k21rs002-wr" in repos
      assert "k94gjk01-master" in repos
    end

    test "filters by type when specified" do
      {:ok, repos} =
        PropagateWorkflow.get_target_repositories(
          [],
          [all: true, type: "sotsuron"],
          repositories: @test_repositories
        )

      assert repos == ["k21rs001-sotsuron"]
    end

    test "thesis type includes both sotsuron and master" do
      {:ok, repos} =
        PropagateWorkflow.get_target_repositories(
          [],
          [all: true, type: "thesis"],
          repositories: @test_repositories
        )

      assert length(repos) == 2
      assert "k21rs001-sotsuron" in repos
      assert "k94gjk01-master" in repos
    end

    test "returns error when no repo specified and --all not set" do
      {:error, message} =
        PropagateWorkflow.get_target_repositories(
          [],
          [all: false],
          repositories: @test_repositories
        )

      assert message =~ "Repository name required"
    end
  end

  describe "sort_draft_branches/1" do
    test "sorts branches by numeric prefix" do
      branches = ["2nd-draft", "0th-draft", "1st-draft", "3rd-draft"]
      {:ok, sorted} = PropagateWorkflow.sort_draft_branches(branches)

      assert sorted == ["0th-draft", "1st-draft", "2nd-draft", "3rd-draft"]
    end

    test "handles single branch" do
      {:ok, sorted} = PropagateWorkflow.sort_draft_branches(["0th-draft"])
      assert sorted == ["0th-draft"]
    end

    test "handles empty list" do
      {:ok, sorted} = PropagateWorkflow.sort_draft_branches([])
      assert sorted == []
    end

    test "handles higher numbers" do
      branches = ["10th-draft", "4th-draft", "5th-draft"]
      {:ok, sorted} = PropagateWorkflow.sort_draft_branches(branches)

      assert sorted == ["4th-draft", "5th-draft", "10th-draft"]
    end
  end

  describe "process_single_repository/3 with no issues" do
    test "returns no_action_needed when all branches are OK" do
      test_params = [
        branches: %{"test-repo" => ["0th-draft", "1st-draft", "2nd-draft"]},
        compare_results: %{"test-repo" => []}
      ]

      {:ok, result} =
        PropagateWorkflow.process_single_repository("test-repo", [dry_run: false], test_params)

      assert result == :no_action_needed
    end
  end

  describe "process_single_repository/3 with issues" do
    test "returns dry_run info when --dry-run is set" do
      test_params = [
        branches: %{"test-repo" => ["0th-draft", "1st-draft", "2nd-draft"]},
        compare_results: %{
          "test-repo" => [{"main", "0th-draft", 2}, {"1st-draft", "2nd-draft", 3}]
        }
      ]

      {:ok, result} =
        PropagateWorkflow.process_single_repository("test-repo", [dry_run: true], test_params)

      assert {:dry_run, issues} = result
      assert length(issues) == 2
    end

    test "propagates changes when issues exist and not dry_run" do
      test_params = [
        branches: %{"test-repo" => ["0th-draft", "1st-draft"]},
        compare_results: %{"test-repo" => [{"main", "0th-draft", 1}]},
        mock_git: true
      ]

      {:ok, result} =
        PropagateWorkflow.process_single_repository("test-repo", [dry_run: false], test_params)

      assert {:propagated, %{merged: 1, up_to_date: 0}} = result
    end

    test "propagates a repository failure through run/3 with non-ok result" do
      test_params = [
        branches: %{"test-repo" => ["0th-draft", "1st-draft"]},
        compare_results: %{"test-repo" => [{"main", "0th-draft", 1}]},
        mock_git: {:error, "Merge conflict while merging main into 0th-draft"}
      ]

      assert {:error, output} =
               PropagateWorkflow.run(["test-repo"], [dry_run: false], test_params)

      assert output =~ "❌ test-repo: Error - Merge conflict while merging main into 0th-draft"
    end
  end

  describe "format_propagation_failure/1" do
    test "formats a conflict failure with branches, types, paths, progress, and skipped pairs" do
      failure = %{
        kind: :conflict,
        lower: "2nd-draft",
        upper: "3rd-draft",
        types: ["modify/delete"],
        paths: [".github/workflows/ai-reviewer.yml"],
        reason: "CONFLICT (modify/delete): ...",
        merged: 2,
        up_to_date: 1,
        skipped: [{"3rd-draft", "4th-draft"}, {"4th-draft", "5th-draft"}]
      }

      message = PropagateWorkflow.format_propagation_failure(failure)

      assert message =~ "Merge conflict (modify/delete) while merging 2nd-draft into 3rd-draft"
      assert message =~ ".github/workflows/ai-reviewer.yml"
      assert message =~ "merged 2 branch(es), 1 already up-to-date"
      assert message =~ "3rd-draft → 4th-draft"
      assert message =~ "4th-draft → 5th-draft"
      assert message =~ "Resolve the conflict manually"
    end

    test "formats a non-conflict git failure" do
      failure = %{
        kind: :git,
        lower: "main",
        upper: "0th-draft",
        types: [],
        paths: [],
        reason: "fatal: unable to access remote",
        merged: 0,
        up_to_date: 0,
        skipped: []
      }

      message = PropagateWorkflow.format_propagation_failure(failure)

      assert message =~ "Git operation failed while merging main into 0th-draft"
      assert message =~ "fatal: unable to access remote"
      refute message =~ "Resolve the conflict manually"
    end
  end

  describe "format_results/2" do
    test "formats no_action_needed result" do
      results = [{"test-repo", {:ok, :no_action_needed}}]
      output = PropagateWorkflow.format_results(results, dry_run: false)

      assert output =~ "✅ test-repo: All branches OK"
    end

    test "formats dry_run result with issues" do
      results = [{"test-repo", {:ok, {:dry_run, [{"main", "0th-draft", 2}]}}}]
      output = PropagateWorkflow.format_results(results, dry_run: true)

      assert output =~ "📋 test-repo: Would merge:"
      assert output =~ "0th-draft is missing 2 commits from main"
    end

    test "formats propagated result distinguishing merged from up-to-date" do
      results = [{"test-repo", {:ok, {:propagated, %{merged: 2, up_to_date: 1}}}}]
      output = PropagateWorkflow.format_results(results, dry_run: false)

      assert output =~ "✅ test-repo: Merged 2 branch(es), 1 already up-to-date"
    end

    test "formats error result" do
      results = [{"test-repo", {:error, "Failed to clone"}}]
      output = PropagateWorkflow.format_results(results, dry_run: false)

      assert output =~ "❌ test-repo: Error - Failed to clone"
    end
  end

  describe "get_template_repo/1" do
    test "returns sotsuron-template for sotsuron repository" do
      assert PropagateWorkflow.get_template_repo("k21rs001-sotsuron") == "sotsuron-template"
    end

    test "returns sotsuron-template for master repository" do
      assert PropagateWorkflow.get_template_repo("k94gjk01-master") == "sotsuron-template"
    end

    test "returns nil for non-thesis repository" do
      assert PropagateWorkflow.get_template_repo("k21rs001-wr") == nil
    end
  end

  describe "get_workflow_files/0" do
    test "returns list of workflow files to propagate" do
      files = PropagateWorkflow.get_workflow_files()

      assert is_list(files)
      assert ".github/workflows/prevent-draft-merge.yml" in files
    end
  end

  describe "process_single_repository/3 with --from-template" do
    test "applies template and propagates in dry_run mode" do
      test_params = [
        branches: %{"test-repo" => ["0th-draft", "1st-draft"]},
        compare_results: %{"test-repo" => []},
        template_files: %{
          ".github/workflows/prevent-draft-merge.yml" => "new content"
        },
        current_files: %{
          "test-repo" => %{
            ".github/workflows/prevent-draft-merge.yml" => "old content"
          }
        },
        mock_git: true
      ]

      {:ok, result} =
        PropagateWorkflow.process_single_repository(
          "test-repo",
          [dry_run: true, from_template: true],
          test_params
        )

      assert {:dry_run, details} = result
      assert details[:template_updates] == [".github/workflows/prevent-draft-merge.yml"]
    end

    test "skips template apply when files are identical" do
      test_params = [
        branches: %{"test-repo" => ["0th-draft", "1st-draft"]},
        compare_results: %{"test-repo" => []},
        template_files: %{
          ".github/workflows/prevent-draft-merge.yml" => "same content"
        },
        current_files: %{
          "test-repo" => %{
            ".github/workflows/prevent-draft-merge.yml" => "same content"
          }
        },
        mock_git: true
      ]

      {:ok, result} =
        PropagateWorkflow.process_single_repository(
          "test-repo",
          [dry_run: true, from_template: true],
          test_params
        )

      # No template updates needed, and no branch issues
      assert result == :no_action_needed
    end

    test "applies template changes when not dry_run" do
      test_params = [
        branches: %{"test-repo" => ["0th-draft", "1st-draft"]},
        compare_results: %{"test-repo" => []},
        template_files: %{
          ".github/workflows/prevent-draft-merge.yml" => "new content"
        },
        current_files: %{
          "test-repo" => %{
            ".github/workflows/prevent-draft-merge.yml" => "old content"
          }
        },
        mock_git: true
      ]

      {:ok, result} =
        PropagateWorkflow.process_single_repository(
          "test-repo",
          [dry_run: false, from_template: true],
          test_params
        )

      assert {:applied_and_propagated, details} = result
      assert details[:template_files] == 1
    end
  end

  describe "format_results/2 with --from-template" do
    test "formats dry_run result with template updates" do
      results = [
        {"test-repo",
         {:ok,
          {:dry_run,
           %{
             template_updates: [".github/workflows/prevent-draft-merge.yml"],
             branch_issues: []
           }}}}
      ]

      output = PropagateWorkflow.format_results(results, dry_run: true, from_template: true)

      assert output =~ "test-repo"
      assert output =~ "prevent-draft-merge.yml"
    end

    test "formats applied_and_propagated result" do
      results = [
        {"test-repo",
         {:ok,
          {:applied_and_propagated, %{template_files: 1, branches: %{merged: 2, up_to_date: 0}}}}}
      ]

      output = PropagateWorkflow.format_results(results, dry_run: false, from_template: true)

      assert output =~ "test-repo"
      assert output =~ "Applied 1 file"
    end
  end

  describe "check_template_updates error handling" do
    test "treats file_not_found error as needing update" do
      test_params = [
        branches: %{"test-repo" => ["0th-draft"]},
        compare_results: %{"test-repo" => []},
        template_files: %{
          ".github/workflows/prevent-draft-merge.yml" => "new content"
        },
        current_files: %{
          # File doesn't exist in target
          "test-repo" => %{}
        },
        mock_git: true
      ]

      {:ok, result} =
        PropagateWorkflow.process_single_repository(
          "test-repo",
          [dry_run: true, from_template: true],
          test_params
        )

      assert {:dry_run, details} = result
      assert details[:template_updates] == [".github/workflows/prevent-draft-merge.yml"]
    end

    test "does not treat template file missing as error" do
      test_params = [
        branches: %{"test-repo" => ["0th-draft"]},
        compare_results: %{"test-repo" => []},
        # Template file doesn't exist
        template_files: %{},
        current_files: %{
          "test-repo" => %{
            ".github/workflows/prevent-draft-merge.yml" => "existing content"
          }
        },
        mock_git: true
      ]

      {:ok, result} =
        PropagateWorkflow.process_single_repository(
          "test-repo",
          [dry_run: true, from_template: true],
          test_params
        )

      # No updates needed because template file is nil
      assert result == :no_action_needed
    end
  end

  describe "run/3 integration" do
    test "processes single repository in dry_run mode" do
      test_params = [
        branches: %{"test-repo" => ["0th-draft", "1st-draft"]},
        compare_results: %{"test-repo" => []}
      ]

      {:ok, output} = PropagateWorkflow.run(["test-repo"], [dry_run: true], test_params)

      assert output =~ "✅ test-repo: All branches OK"
    end

    test "processes multiple repositories with --all option" do
      test_params = [
        repositories: @test_repositories,
        branches: %{
          "k21rs001-sotsuron" => ["0th-draft", "1st-draft"],
          "k21rs002-wr" => ["0th-draft"],
          "k94gjk01-master" => ["0th-draft", "1st-draft", "2nd-draft"]
        },
        compare_results: %{
          "k21rs001-sotsuron" => [],
          "k21rs002-wr" => [],
          "k94gjk01-master" => []
        }
      ]

      {:ok, output} = PropagateWorkflow.run([], [all: true, dry_run: true], test_params)

      assert output =~ "k21rs001-sotsuron"
      assert output =~ "k21rs002-wr"
      assert output =~ "k94gjk01-master"
    end
  end
end
