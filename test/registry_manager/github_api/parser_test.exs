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
end
