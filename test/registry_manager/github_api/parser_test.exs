defmodule RegistryManager.GitHubAPI.ParserTest do
  use ExUnit.Case, async: true

  alias RegistryManager.GitHubAPI.Parser

  describe "decode_file_response/1" do
    test "successfully decodes valid GitHub file response" do
      # Test data that mimics GitHub API response structure
      sample_data = %{"test" => "data", "student_id" => "k21rs001"}
      json_content = Jason.encode!(sample_data)
      encoded_content = Base.encode64(json_content)

      github_response = %{
        "content" => encoded_content,
        "sha" => "abc123def456"
      }

      assert {:ok, {decoded_data, sha}} = Parser.decode_file_response(github_response)
      assert decoded_data == sample_data
      assert sha == "abc123def456"
    end

    test "handles invalid response format" do
      invalid_response = %{"invalid" => "format"}

      assert {:error, "Invalid file response format"} =
               Parser.decode_file_response(invalid_response)
    end

    test "handles base64 decode errors" do
      github_response = %{
        "content" => "invalid_base64!!!",
        "sha" => "abc123"
      }

      assert {:error, "Base64 decode failed"} = Parser.decode_file_response(github_response)
    end

    test "handles JSON decode errors" do
      invalid_json = "{ invalid json"
      encoded_content = Base.encode64(invalid_json)

      github_response = %{
        "content" => encoded_content,
        "sha" => "abc123"
      }

      assert {:error, "JSON decode failed"} = Parser.decode_file_response(github_response)
    end
  end

  describe "encode_file_content/1" do
    test "successfully encodes data for GitHub API" do
      sample_data = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron"
        }
      }

      assert {:ok, encoded_content} = Parser.encode_file_content(sample_data)
      assert is_binary(encoded_content)

      # Verify round-trip encoding/decoding
      decoded = Base.decode64!(encoded_content)
      assert {:ok, decoded_data} = Jason.decode(decoded)
      assert decoded_data == sample_data
    end

    test "handles encoding errors gracefully" do
      # Test with data that can't be JSON encoded (functions, etc.)
      invalid_data = %{function: fn -> :test end}

      assert {:error, error_message} = Parser.encode_file_content(invalid_data)
      assert String.contains?(error_message, "JSON encoding failed")
    end
  end

  describe "extract_repository_activity/1" do
    test "extracts pushed_at timestamp" do
      response = %{"pushed_at" => "2025-07-01T12:00:00Z"}
      assert {:ok, "2025-07-01T12:00:00Z"} = Parser.extract_repository_activity(response)
    end

    test "falls back to updated_at when pushed_at is not available" do
      response = %{"updated_at" => "2025-07-01T10:00:00Z"}
      assert {:ok, "2025-07-01T10:00:00Z"} = Parser.extract_repository_activity(response)
    end

    test "handles missing timestamp fields" do
      response = %{"other_field" => "value"}

      assert {:error, "No activity timestamp found"} =
               Parser.extract_repository_activity(response)
    end
  end

  describe "extract_latest_commit_date/1" do
    test "extracts date from commit list" do
      commits = [
        %{
          "commit" => %{
            "author" => %{"date" => "2025-07-01T12:00:00Z"}
          }
        }
      ]

      assert {:ok, "2025-07-01T12:00:00Z"} = Parser.extract_latest_commit_date(commits)
    end

    test "handles empty commit list" do
      assert {:error, "No commits found"} = Parser.extract_latest_commit_date([])
    end

    test "handles invalid commit structure" do
      invalid_commits = [%{"invalid" => "structure"}]

      assert {:error, "Unexpected commit response format"} =
               Parser.extract_latest_commit_date(invalid_commits)
    end
  end

  describe "find_github_username_for_student/2" do
    setup do
      test_data = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "github_username" => "student001"
        },
        "k21rs002-wr" => %{
          "student_id" => "k21rs002"
          # No github_username field
        }
      }

      {:ok, test_data: test_data}
    end

    test "finds GitHub username for existing student", %{test_data: test_data} do
      assert {:ok, "student001"} = Parser.find_github_username_for_student(test_data, "k21rs001")
    end

    test "handles missing GitHub username", %{test_data: test_data} do
      assert {:error, "GitHub username not found in registry"} =
               Parser.find_github_username_for_student(test_data, "k21rs002")
    end

    test "handles non-existent student", %{test_data: test_data} do
      assert {:error, "No repository found for student"} =
               Parser.find_github_username_for_student(test_data, "k99rs999")
    end
  end

  describe "extract_github_username_from_repo_info/1" do
    test "extracts valid GitHub username" do
      repo_info = %{"github_username" => "student001"}
      assert {:ok, "student001"} = Parser.extract_github_username_from_repo_info(repo_info)
    end

    test "handles missing GitHub username field" do
      repo_info = %{"other_field" => "value"}

      assert {:error, "GitHub username not found in registry"} =
               Parser.extract_github_username_from_repo_info(repo_info)
    end

    test "handles empty GitHub username" do
      repo_info = %{"github_username" => ""}

      assert {:error, "Invalid GitHub username format"} =
               Parser.extract_github_username_from_repo_info(repo_info)
    end

    test "handles invalid GitHub username type" do
      repo_info = %{"github_username" => 123}

      assert {:error, "Invalid GitHub username format"} =
               Parser.extract_github_username_from_repo_info(repo_info)
    end
  end

  describe "validate_test_safety/3" do
    @configured_test_ids ["k92rs123", "k21rs001", "k21rs002", "k91gjk01"]

    test "allows non-test repositories in production" do
      assert :ok = Parser.validate_test_safety("k99rs999-real-repo", true, @configured_test_ids)
    end

    test "prevents test repositories in production" do
      test_repos = [
        "k21rs001-test-repo",
        "k92rs123-sotsuron",
        "test-repo-example"
      ]

      for repo_name <- test_repos do
        assert {:error, error_message} =
                 Parser.validate_test_safety(repo_name, true, @configured_test_ids)

        assert String.contains?(error_message, "SAFETY ERROR")
        assert String.contains?(error_message, repo_name)
      end
    end

    test "allows all repositories in test mode" do
      test_repos = [
        "k21rs001-test-repo",
        "k92rs123-sotsuron",
        "test-repo-example",
        "production-repo"
      ]

      for repo_name <- test_repos do
        assert :ok = Parser.validate_test_safety(repo_name, false, @configured_test_ids)
      end
    end

    test "without configured test IDs only built-in patterns are checked" do
      assert :ok = Parser.validate_test_safety("k92rs123-sotsuron", true)
      assert {:error, _} = Parser.validate_test_safety("test-repo-example", true)
    end
  end

  describe "decode_base64_content/1" do
    test "successfully decodes valid base64 content" do
      original = "Hello, World!"
      encoded = Base.encode64(original)
      assert {:ok, decoded} = Parser.decode_base64_content(encoded)
      assert decoded == original
    end

    test "handles invalid base64 content" do
      invalid_base64 = "invalid_base64!!!"
      assert {:error, "Base64 decode failed"} = Parser.decode_base64_content(invalid_base64)
    end

    test "handles base64 with newlines (GitHub API format)" do
      original = "Multi-line content"
      encoded = Base.encode64(original)
      encoded_with_newlines = String.replace(encoded, "", "\n")

      assert {:ok, decoded} = Parser.decode_base64_content(encoded_with_newlines)
      assert decoded == original
    end
  end

  describe "decode_json_content/1" do
    test "successfully decodes valid JSON" do
      sample_data = %{"key" => "value", "number" => 42}
      json_string = Jason.encode!(sample_data)

      assert {:ok, decoded} = Parser.decode_json_content(json_string)
      assert decoded == sample_data
    end

    test "handles invalid JSON" do
      invalid_json = "{ invalid json"
      assert {:error, "JSON decode failed"} = Parser.decode_json_content(invalid_json)
    end
  end

  describe "detect_environment_mode/0" do
    test "detects test environment" do
      # This test will always pass in the test environment
      assert Parser.detect_environment_mode() == :test
    end
  end

  describe "organization_owner?/1" do
    test "identifies organization accounts" do
      assert Parser.organization_owner?("smkwlab") == true
      assert Parser.organization_owner?("github") == true
      assert Parser.organization_owner?("microsoft") == true
    end

    test "identifies individual student accounts" do
      assert Parser.organization_owner?("k21rs001") == false
      assert Parser.organization_owner?("k22gjk001") == false
      assert Parser.organization_owner?("k93cs099") == false
    end

    test "handles edge cases" do
      # Not student ID pattern
      assert Parser.organization_owner?("user123") == true
      # Too short
      assert Parser.organization_owner?("k21") == true
      # Empty string
      assert Parser.organization_owner?("") == true
    end
  end

  describe "extract_actual_developer/1" do
    test "extracts most frequent commit author" do
      commits = [
        %{"author" => %{"login" => "k21rs001"}},
        %{"author" => %{"login" => "k21rs001"}},
        %{"author" => %{"login" => "k21rs002"}},
        %{"author" => %{"login" => "k21rs001"}}
      ]

      assert {:ok, "k21rs001"} = Parser.extract_actual_developer(commits)
    end

    test "filters out automation accounts and prioritizes student accounts" do
      commits = [
        %{"author" => %{"login" => "actions-user"}},
        %{"author" => %{"login" => "actions-user"}},
        %{"author" => %{"login" => "actions-user"}},
        %{"author" => %{"login" => "k19rs999"}},
        %{"author" => %{"login" => "k19rs999"}},
        %{"author" => %{"login" => "smkwlab"}}
      ]

      # actions-userが最頻出でも、学生アカウントk19rs999が優先される
      assert {:ok, "k19rs999"} = Parser.extract_actual_developer(commits)
    end

    test "handles commits with nil authors" do
      commits = [
        %{"author" => %{"login" => "k21rs001"}},
        %{"author" => nil},
        %{"author" => %{"login" => "k21rs001"}},
        %{"author" => %{"login" => "k21rs002"}}
      ]

      assert {:ok, "k21rs001"} = Parser.extract_actual_developer(commits)
    end

    test "falls back to automation accounts when only automation commits exist" do
      commits = [
        %{"author" => %{"login" => "actions-user"}},
        %{"author" => %{"login" => "github-actions"}},
        %{"author" => %{"login" => "actions-user"}}
      ]

      # 学生のコミットがない場合は自動化アカウントから選択
      assert {:ok, "actions-user"} = Parser.extract_actual_developer(commits)
    end

    test "returns error when no valid authors found" do
      commits = [
        %{"author" => nil},
        %{"author" => %{"login" => nil}},
        %{}
      ]

      assert {:error, "No valid commit authors found"} = Parser.extract_actual_developer(commits)
    end

    test "returns error for invalid input" do
      assert {:error, "Invalid commits response format"} =
               Parser.extract_actual_developer("invalid")

      assert {:error, "Invalid commits response format"} = Parser.extract_actual_developer(%{})
    end
  end

  describe "filter_automation_accounts/2" do
    test "filters out common automation accounts" do
      logins = [
        "k21rs001",
        "actions-user",
        "github-actions",
        "k21rs002",
        "dependabot[bot]"
      ]

      filtered = Parser.filter_automation_accounts(logins)

      assert filtered == ["k21rs001", "k21rs002"]
    end

    test "filters out the organization account when org is given" do
      logins = ["k21rs001", "myorg", "k21rs002"]

      assert Parser.filter_automation_accounts(logins, "myorg") == ["k21rs001", "k21rs002"]
      # org 未指定なら組織アカウント名は除外されない
      assert Parser.filter_automation_accounts(logins) == logins
    end

    test "ignores empty-string org (defensive)" do
      logins = ["k21rs001", "k21rs002"]

      assert Parser.filter_automation_accounts(logins, "") == logins
    end

    test "returns original list when all accounts are automation" do
      logins = ["actions-user", "github-actions", "dependabot[bot]"]

      filtered = Parser.filter_automation_accounts(logins)

      # すべて自動化アカウントの場合は元のリストを返す
      assert filtered == logins
    end

    test "handles empty list" do
      assert Parser.filter_automation_accounts([]) == []
    end
  end

  # Issue #115: Tests for requested reviewers and review status
  describe "extract_requested_reviewers/1" do
    test "extracts user logins from requested reviewers response" do
      response = %{
        "users" => [
          %{"login" => "user1"},
          %{"login" => "user2"}
        ],
        "teams" => []
      }

      result = Parser.extract_requested_reviewers(response)
      assert result.users == ["user1", "user2"]
      assert result.teams == []
    end

    test "extracts team slugs from requested reviewers response" do
      response = %{
        "users" => [],
        "teams" => [
          %{"slug" => "team1"},
          %{"slug" => "team2"}
        ]
      }

      result = Parser.extract_requested_reviewers(response)
      assert result.users == []
      assert result.teams == ["team1", "team2"]
    end

    test "handles empty response" do
      response = %{
        "users" => [],
        "teams" => []
      }

      result = Parser.extract_requested_reviewers(response)
      assert result.users == []
      assert result.teams == []
    end

    test "handles invalid response" do
      result = Parser.extract_requested_reviewers(%{})
      assert result == %{users: [], teams: []}

      result = Parser.extract_requested_reviewers(nil)
      assert result == %{users: [], teams: []}
    end

    # Issue #118: Support PR object format (requested_reviewers/requested_teams)
    test "extracts from PR object format (requested_reviewers field)" do
      pr_object = %{
        "number" => 1,
        "state" => "open",
        "requested_reviewers" => [
          %{"login" => "reviewer1"},
          %{"login" => "reviewer2"}
        ],
        "requested_teams" => [
          %{"slug" => "team-a"}
        ]
      }

      result = Parser.extract_requested_reviewers(pr_object)
      assert result.users == ["reviewer1", "reviewer2"]
      assert result.teams == ["team-a"]
    end

    test "handles PR object with empty requested_reviewers" do
      pr_object = %{
        "number" => 1,
        "state" => "open",
        "requested_reviewers" => [],
        "requested_teams" => []
      }

      result = Parser.extract_requested_reviewers(pr_object)
      assert result.users == []
      assert result.teams == []
    end

    test "handles PR object with nil requested_reviewers" do
      pr_object = %{
        "number" => 1,
        "state" => "open"
        # requested_reviewers and requested_teams not present
      }

      result = Parser.extract_requested_reviewers(pr_object)
      assert result == %{users: [], teams: []}
    end
  end

  describe "user_has_pending_review_request?/2" do
    test "returns true when user is in requested reviewers" do
      requested = %{users: ["user1", "user2"], teams: []}
      assert Parser.user_has_pending_review_request?(requested, "user1") == true
    end

    test "returns false when user is not in requested reviewers" do
      requested = %{users: ["user1", "user2"], teams: []}
      assert Parser.user_has_pending_review_request?(requested, "user3") == false
    end

    test "is case insensitive" do
      requested = %{users: ["User1"], teams: []}
      assert Parser.user_has_pending_review_request?(requested, "user1") == true
      assert Parser.user_has_pending_review_request?(requested, "USER1") == true
    end

    test "returns false for invalid inputs" do
      assert Parser.user_has_pending_review_request?(nil, "user1") == false
      assert Parser.user_has_pending_review_request?(%{}, nil) == false
    end
  end

  describe "pr_awaiting_review_from?/2" do
    test "returns true when user is in the PR's requested_reviewers" do
      # requested_reviewers への所属だけで「いまレビュー待ちか」が決まる。
      # GitHub はレビュー提出でユーザーを requested_reviewers から外し、
      # 再リクエストで戻すため、過去のレビュー提出履歴(reviews)は参照しない
      pr = %{
        "number" => 3,
        "requested_reviewers" => [%{"login" => "prof-a"}],
        "requested_teams" => []
      }

      assert Parser.pr_awaiting_review_from?(pr, "prof-a") == true
    end

    test "returns false when user is not in requested_reviewers" do
      pr = %{
        "number" => 3,
        "requested_reviewers" => [%{"login" => "other-prof"}],
        "requested_teams" => []
      }

      assert Parser.pr_awaiting_review_from?(pr, "prof-a") == false
    end

    test "is case insensitive" do
      pr = %{"requested_reviewers" => [%{"login" => "Prof-A"}], "requested_teams" => []}
      assert Parser.pr_awaiting_review_from?(pr, "prof-a") == true
    end

    test "returns false for a PR object without reviewer fields" do
      assert Parser.pr_awaiting_review_from?(%{"number" => 1}, "prof-a") == false
    end
  end

  describe "extract_pr_status/1" do
    test "extracts PR status with counts" do
      pull_requests = [
        %{"state" => "open", "draft" => false, "merged_at" => nil},
        %{"state" => "open", "draft" => true, "merged_at" => nil},
        %{"state" => "closed", "draft" => false, "merged_at" => "2025-01-01T00:00:00Z"}
      ]

      assert {:ok, status} = Parser.extract_pr_status(pull_requests)
      assert status.total == 3
      assert status.open == 2
      assert status.closed == 1
      assert status.merged == 1
      assert status.draft == 1
    end

    test "extracts timestamps from PRs" do
      # Issue #115: Timestamps are used for sorting PRs by activity
      # Both updated_at and created_at use max (most recent) because:
      # - "-t updated": Show repos with recently UPDATED PRs first
      # - "-t created": Show repos with recently CREATED PRs first
      # The purpose is to surface recently active repositories, not to find
      # the "first ever PR" in the repository.
      pull_requests = [
        %{
          "state" => "open",
          "updated_at" => "2025-01-15T10:00:00Z",
          "created_at" => "2025-01-10T08:00:00Z"
        },
        %{
          "state" => "open",
          "updated_at" => "2025-01-20T12:00:00Z",
          "created_at" => "2025-01-12T09:00:00Z"
        }
      ]

      assert {:ok, status} = Parser.extract_pr_status(pull_requests)
      # Should get the most recent timestamp for both fields (for sorting by recent activity)
      assert status.updated_at == "2025-01-20T12:00:00Z"
      assert status.created_at == "2025-01-12T09:00:00Z"
    end

    test "returns nil timestamps for empty PR list" do
      assert {:ok, status} = Parser.extract_pr_status([])
      assert status.total == 0
      assert status.updated_at == nil
      assert status.created_at == nil
    end

    test "handles PRs with missing timestamps" do
      pull_requests = [
        %{"state" => "open"},
        %{"state" => "closed", "updated_at" => "2025-01-15T10:00:00Z"}
      ]

      assert {:ok, status} = Parser.extract_pr_status(pull_requests)
      assert status.updated_at == "2025-01-15T10:00:00Z"
      assert status.created_at == nil
    end

    test "returns error for invalid input" do
      assert {:error, _} = Parser.extract_pr_status(nil)
      assert {:error, _} = Parser.extract_pr_status("invalid")
    end
  end
end
