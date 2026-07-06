defmodule RegistryManager.RepositoryInferenceTest do
  use ExUnit.Case, async: true

  alias RegistryManager.Repository
  alias RegistryManager.Test.GitHubAPIMock

  describe "add_with_inference/2" do
    setup do
      Application.put_env(:registry_manager, :env, :test)
      Application.put_env(:registry_manager, :use_github_mock, true)

      # Reset mock responses for clean state
      GitHubAPIMock.reset_mock_responses()

      on_exit(fn ->
        Application.put_env(:registry_manager, :env, :test)
        Application.delete_env(:registry_manager, :use_github_mock)
        GitHubAPIMock.reset_mock_responses()
      end)
    end

    test "successfully infers student_id from CSV via GitHub owner" do
      # Setup mock responses
      GitHubAPIMock.set_mock_response(:get_repository_info, fn repo_name ->
        assert repo_name == "smkwlab/k21rs001-sotsuron"

        {:ok,
         %{
           "owner" => %{"login" => "taro-yamada"},
           "created_at" => "2025-01-01T00:00:00Z"
         }}
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn new_data, _sha, _message ->
        assert new_data["k21rs001-sotsuron"]["student_id"] == "k21rs001"
        assert new_data["k21rs001-sotsuron"]["repository_type"] == "sotsuron"
        assert new_data["k21rs001-sotsuron"]["github_username"] == "taro-yamada"
        {:ok, "Success"}
      end)

      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {%{}, "mock_sha"}}
      end)

      # Execute
      assert {:ok, _} = Repository.add_with_inference("k21rs001-sotsuron")
    end

    test "fails when GitHub owner not found in CSV (no fallback to repo name)" do
      # Setup mock responses
      GitHubAPIMock.set_mock_response(:get_repository_info, fn repo_name ->
        assert repo_name == "smkwlab/k21rs003-wr"

        {:ok,
         %{
           "owner" => %{"login" => "unknown-user"},
           "created_at" => "2025-01-01T00:00:00Z"
         }}
      end)

      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {%{}, "mock_sha"}}
      end)

      # Execute - should fail since we don't fall back to repo name anymore
      assert {:error, "Cannot determine student ID for unknown-user"} =
               Repository.add_with_inference("k21rs003-wr")
    end

    test "handles full repository path (org/repo)" do
      # Setup mock responses
      GitHubAPIMock.set_mock_response(:get_repository_info, fn repo_name ->
        assert repo_name == "smkwlab/k21rs002-ise"

        {:ok,
         %{
           "owner" => %{"login" => "hanako-suzuki"},
           "created_at" => "2025-01-01T00:00:00Z"
         }}
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn new_data, _sha, _message ->
        # Repository key should not have org prefix
        repo_key = "k21rs002-ise"

        assert Map.has_key?(new_data, repo_key),
               "Expected key #{repo_key} not found in #{inspect(Map.keys(new_data))}"

        assert new_data[repo_key]["student_id"] == "k21rs002"
        assert new_data[repo_key]["repository_type"] == "ise"
        {:ok, "Success"}
      end)

      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {%{}, "mock_sha"}}
      end)

      # Execute
      assert {:ok, _} = Repository.add_with_inference("smkwlab/k21rs002-ise")
    end

    test "returns error when repository type cannot be inferred" do
      # Setup mock responses
      GitHubAPIMock.set_mock_response(:get_repository_info, fn _repo_name ->
        {:ok,
         %{
           "owner" => %{"login" => "test-user"},
           "created_at" => "2025-01-01T00:00:00Z"
         }}
      end)

      # Execute - this will fail because student ID cannot be determined from "test-repository"
      # and repository type also cannot be inferred
      assert {:error, "Cannot determine student ID for test-user"} =
               Repository.add_with_inference("test-repository")
    end

    test "returns error when student ID cannot be determined" do
      # Setup mock responses
      GitHubAPIMock.set_mock_response(:get_repository_info, fn _repo_name ->
        {:ok,
         %{
           "owner" => %{"login" => "unknown-user"},
           "created_at" => "2025-01-01T00:00:00Z"
         }}
      end)

      # Execute
      assert {:error, "Cannot determine student ID for unknown-user"} =
               Repository.add_with_inference("invalid-repo-wr")
    end

    test "returns error when repository doesn't exist" do
      # Setup mock responses
      GitHubAPIMock.set_mock_response(:get_repository_info, fn _repo_name ->
        {:error, "Repository not found"}
      end)

      # Execute
      assert {:error, "Repository not found"} = Repository.add_with_inference("non-existent-repo")
    end

    test "verbose mode logs inference details" do
      # Setup mock responses
      GitHubAPIMock.set_mock_response(:get_repository_info, fn _repo_name ->
        {:ok,
         %{
           "owner" => %{"login" => "taro-yamada"},
           "created_at" => "2025-01-01T00:00:00Z"
         }}
      end)

      GitHubAPIMock.set_mock_response(
        :update_repositories_json,
        fn _new_data, _sha, _message ->
          {:ok, "Success"}
        end
      )

      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {%{}, "mock_sha"}}
      end)

      # Execute with verbose mode - just verify it succeeds
      assert {:ok, _} = Repository.add_with_inference("k21rs001-sotsuron", verbose: true)
    end

    test "verbose mode logs failure when GitHub owner not found in CSV" do
      # Setup mock responses
      GitHubAPIMock.set_mock_response(:get_repository_info, fn _repo_name ->
        {:ok,
         %{
           "owner" => %{"login" => "unknown-user"},
           "created_at" => "2025-01-01T00:00:00Z"
         }}
      end)

      GitHubAPIMock.set_mock_response(:get_repositories_json, fn ->
        {:ok, {%{}, "mock_sha"}}
      end)

      # Execute with verbose mode - should fail since we no longer fallback to repo name
      assert {:error, "Cannot determine student ID for unknown-user"} =
               Repository.add_with_inference("k21rs003-wr", verbose: true)
    end
  end

  describe "infer_repository_type/1" do
    test "infers sotsuron type" do
      assert {:ok, "sotsuron"} = Repository.infer_repository_type("k21rs001-sotsuron")
      assert {:ok, "sotsuron"} = Repository.infer_repository_type("smkwlab/k21rs001-sotsuron")
    end

    test "infers wr type" do
      assert {:ok, "wr"} = Repository.infer_repository_type("k21rs001-wr")
      assert {:ok, "wr"} = Repository.infer_repository_type("k21rs001-wr-2024")
    end

    test "infers ise type" do
      assert {:ok, "ise"} = Repository.infer_repository_type("k21rs001-ise")
      assert {:ok, "ise"} = Repository.infer_repository_type("k21rs001-ise-report")
    end

    test "infers master type" do
      assert {:ok, "master"} = Repository.infer_repository_type("k94gjk04-master")
      assert {:ok, "master"} = Repository.infer_repository_type("smkwlab/k94gjk04-master")
    end

    test "infers other type for thesis repositories" do
      assert {:ok, "other"} = Repository.infer_repository_type("k21rs001-thesis")
    end

    test "infers other type for latex repositories" do
      assert {:ok, "other"} = Repository.infer_repository_type("k21rs001-latex")
    end

    test "infers other type for poster repositories" do
      assert {:ok, "other"} = Repository.infer_repository_type("k95gjk05-midterm-poster")
    end

    test "infers other type for conference paper repositories" do
      assert {:ok, "other"} = Repository.infer_repository_type("k95gjk01-wakate-ronbun")
    end

    test "infers other type for unknown patterns" do
      assert {:ok, "other"} = Repository.infer_repository_type("k21rs001-unknown")
      assert {:ok, "other"} = Repository.infer_repository_type("test-repository")
    end
  end

  describe "get_student_id_from_csv_by_github/1" do
    setup do
      Application.put_env(:registry_manager, :env, :test)
      on_exit(fn -> Application.put_env(:registry_manager, :env, :test) end)
    end

    test "finds student ID for known GitHub username" do
      assert {:ok, "k21rs001"} = Repository.get_student_id_from_csv_by_github("taro-yamada")
    end

    test "finds student ID for another known GitHub username" do
      assert {:ok, "k21rs002"} = Repository.get_student_id_from_csv_by_github("hanako-suzuki")
    end

    test "returns error for unknown GitHub username" do
      assert {:error, "GitHub username not found in CSV"} =
               Repository.get_student_id_from_csv_by_github("unknown-user")
    end

    test "handles normalized student ID format" do
      # CSV might contain "21RS001" which should be normalized to "k21rs001"
      assert {:ok, "k21rs003"} = Repository.get_student_id_from_csv_by_github("jiro-tanaka")
    end

    test "finds student ID for k91rs012" do
      assert {:ok, "k91rs012"} = Repository.get_student_id_from_csv_by_github("k91rs012")
    end
  end

  describe "get_actual_repository_developer/3" do
    setup do
      Application.put_env(:registry_manager, :env, :test)
      Application.put_env(:registry_manager, :use_github_mock, true)

      # Reset mock responses for clean state
      GitHubAPIMock.reset_mock_responses()

      on_exit(fn ->
        Application.put_env(:registry_manager, :env, :test)
        Application.delete_env(:registry_manager, :use_github_mock)
        GitHubAPIMock.reset_mock_responses()
      end)
    end

    test "detects organization owner and gets actual developer from commits" do
      repo_info = %{
        "owner" => %{"login" => "smkwlab"},
        "created_at" => "2025-01-01T00:00:00Z"
      }

      GitHubAPIMock.set_mock_response(:get_actual_developer, fn repo_name, _opts ->
        assert repo_name == "smkwlab/sampleuser-wr"
        {:ok, "k91rs012"}
      end)

      assert {:ok, "k91rs012"} =
               Repository.get_actual_repository_developer("smkwlab/sampleuser-wr", repo_info,
                 verbose: true
               )
    end

    test "returns original owner for individual repositories" do
      repo_info = %{
        "owner" => %{"login" => "k21rs001"},
        "created_at" => "2025-01-01T00:00:00Z"
      }

      assert {:ok, "k21rs001"} =
               Repository.get_actual_repository_developer("k21rs001-wr", repo_info)
    end

    test "falls back to organization owner when commit analysis fails" do
      repo_info = %{
        "owner" => %{"login" => "smkwlab"},
        "created_at" => "2025-01-01T00:00:00Z"
      }

      GitHubAPIMock.set_mock_response(:get_actual_developer, fn _repo_name, _opts ->
        {:error, "No commits found"}
      end)

      assert {:ok, "smkwlab"} =
               Repository.get_actual_repository_developer("smkwlab/empty-repo", repo_info,
                 verbose: true
               )
    end
  end

  describe "validate_add_request_for_inference/3" do
    test "accepts valid data without repository name validation" do
      # This should pass even though repository name doesn't match student ID
      assert :ok =
               Repository.validate_add_request_for_inference("sampleuser-wr", "k91rs012", "wr")

      assert :ok =
               Repository.validate_add_request_for_inference("my-thesis", "k21rs001", "sotsuron")

      assert :ok =
               Repository.validate_add_request_for_inference(
                 "latex-practice",
                 "k21rs002",
                 "other"
               )
    end

    test "rejects invalid student ID" do
      result = Repository.validate_add_request_for_inference("sampleuser-wr", "invalid-id", "wr")
      assert {:error, msg} = result
      assert msg =~ "repository: sampleuser-wr"
      assert msg =~ "inferred_student_id: invalid-id"
    end

    test "rejects invalid repository type" do
      result =
        Repository.validate_add_request_for_inference("sampleuser-wr", "k91rs012", "invalid-type")

      assert {:error, msg} = result
      assert msg =~ "repository: sampleuser-wr"
      assert msg =~ "inferred_student_id: k91rs012"
    end
  end
end
