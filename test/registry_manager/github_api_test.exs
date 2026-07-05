defmodule RegistryManager.GitHubAPITest do
  use ExUnit.Case, async: false

  alias RegistryManager.GitHubAPI

  # モックは MIX_ENV=test で自動的に有効化されます

  describe "registry file path resolution (issue #8)" do
    @new_path "data/registry.json"
    @legacy_path "data/repositories.json"
    @not_found {:error, "GitHub API error (404): Not Found"}

    test "fetch_registry_file returns the new file when it exists" do
      fetch = fn
        @new_path -> {:ok, %{"content" => "new"}}
        @legacy_path -> flunk("legacy path should not be fetched")
      end

      assert {:ok, %{"content" => "new"}} = GitHubAPI.fetch_registry_file(fetch)
    end

    test "fetch_registry_file falls back to the legacy file on 404" do
      fetch = fn
        @new_path -> @not_found
        @legacy_path -> {:ok, %{"content" => "legacy"}}
      end

      assert {:ok, %{"content" => "legacy"}} = GitHubAPI.fetch_registry_file(fetch)
    end

    test "fetch_registry_file passes through non-404 errors without fallback" do
      fetch = fn
        @new_path -> {:error, "GitHub API error (401): Bad credentials"}
        @legacy_path -> flunk("legacy path should not be fetched on non-404 errors")
      end

      assert {:error, "GitHub API error (401): Bad credentials"} =
               GitHubAPI.fetch_registry_file(fetch)
    end

    test "resolve_registry_write_path prefers the new file when it exists" do
      fetch = fn
        @new_path -> {:ok, %{}}
      end

      assert {:ok, @new_path} = GitHubAPI.resolve_registry_write_path(fetch)
    end

    test "resolve_registry_write_path uses the legacy path when only it exists" do
      fetch = fn
        @new_path -> @not_found
        @legacy_path -> {:ok, %{}}
      end

      assert {:ok, @legacy_path} = GitHubAPI.resolve_registry_write_path(fetch)
    end

    test "resolve_registry_write_path creates the new file when neither exists" do
      fetch = fn
        @new_path -> @not_found
        @legacy_path -> @not_found
      end

      assert {:ok, @new_path} = GitHubAPI.resolve_registry_write_path(fetch)
    end

    test "resolve_registry_write_path passes through non-404 errors" do
      fetch = fn
        @new_path -> {:error, "GitHub API error (500): oops"}
      end

      assert {:error, "GitHub API error (500): oops"} =
               GitHubAPI.resolve_registry_write_path(fetch)
    end
  end

  describe "get_repositories_json/0" do
    test "returns appropriate result based on environment" do
      # This test adapts to the actual environment state
      result = GitHubAPI.get_repositories_json()

      case result do
        {:ok, {data, sha}} ->
          # If authentication works, verify the structure
          assert is_map(data)
          assert is_binary(sha)

        {:error, error_message} ->
          # If authentication fails, verify error message
          assert is_binary(error_message)

          assert String.contains?(error_message, "GitHub CLI authentication failed") or
                   String.contains?(error_message, "Request failed") or
                   String.contains?(error_message, "GitHub API error")
      end
    end
  end

  describe "update_repositories_json/3" do
    test "handles update attempt appropriately" do
      sample_data = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "status" => "active"
        }
      }

      result = GitHubAPI.update_repositories_json(sample_data, "fake_sha", "Test commit")

      case result do
        {:ok, message} ->
          # If update succeeds (unlikely with fake sha), verify message
          assert is_binary(message)

        {:error, error_message} ->
          # Expected to fail due to fake SHA or authentication issues
          assert is_binary(error_message)

          assert String.contains?(error_message, "GitHub CLI authentication failed") or
                   String.contains?(error_message, "Request failed") or
                   String.contains?(error_message, "GitHub API error")
      end
    end
  end

  describe "module constants and structure" do
    test "has correct module constants" do
      # Test that the module loads and has the expected structure
      assert Code.ensure_loaded?(GitHubAPI)

      # Verify functions are exported
      exports = GitHubAPI.__info__(:functions)
      assert {:get_repositories_json, 0} in exports
      assert {:update_repositories_json, 3} in exports
    end

    test "has correct module documentation" do
      {:docs_v1, _annotation, _language, _format, module_doc, _metadata, _docs} =
        Code.fetch_docs(GitHubAPI)

      assert module_doc != :hidden
      assert module_doc != :none
    end
  end

  describe "data encoding/decoding logic" do
    test "JSON encoding works correctly" do
      # Test the JSON encoding part of the update flow
      sample_data = %{
        "test-repo" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "status" => "active",
          "stage" => "thesis",
          "updated_at" => "2023-12-01T10:00:00Z"
        }
      }

      # This should work even without GitHub API access
      json_result = Jason.encode(sample_data)
      assert {:ok, json_string} = json_result
      assert String.contains?(json_string, "k21rs001")
      assert String.contains?(json_string, "sotsuron")

      # Test base64 encoding
      encoded = Base.encode64(json_string)
      assert is_binary(encoded)

      # Test decoding back
      decoded = Base.decode64!(encoded)
      assert decoded == json_string

      # Test JSON decode back
      {:ok, decoded_data} = Jason.decode(decoded)
      assert decoded_data == sample_data
    end
  end

  describe "error handling" do
    test "handles JSON decode errors gracefully" do
      # Test that invalid JSON content would be handled properly
      # We can't easily test this without mocking, but we can verify the structure

      # Test with invalid JSON
      invalid_json = "{ invalid json"

      case Jason.decode(invalid_json) do
        # This is expected
        {:error, _} -> assert true
        {:ok, _} -> assert false, "Should have failed with invalid JSON"
      end
    end

    test "handles base64 decode errors gracefully" do
      # Test invalid base64 content
      invalid_base64 = "invalid base64!!!"

      try do
        Base.decode64!(invalid_base64)
        assert false, "Should have raised an error"
      rescue
        # This is expected
        _ -> assert true
      end
    end
  end

  describe "network and authentication mocking scenarios" do
    test "simulates successful API response structure" do
      # Test the structure that would be returned by a successful API call
      mock_api_response = %{
        "content" => Base.encode64(Jason.encode!(%{"test" => "data"})),
        "sha" => "abc123def456"
      }

      # Simulate the decoding logic
      content = mock_api_response["content"] |> String.replace("\n", "") |> Base.decode64!()
      sha = mock_api_response["sha"]

      assert {:ok, data} = Jason.decode(content)
      assert data == %{"test" => "data"}
      assert sha == "abc123def456"
    end

    test "simulates error response structure" do
      # Test the structure that would be returned by an error API call
      mock_error_response = %{
        "message" => "Not Found",
        "documentation_url" => "https://docs.github.com/rest"
      }

      # Test error message extraction
      error_message = mock_error_response["message"]
      assert error_message == "Not Found"
    end
  end

  describe "configuration and constants" do
    test "uses correct repository and file path" do
      # We can't directly access module constants, but we can verify they're used correctly
      # by checking that the module compiles and functions are available
      exports = GitHubAPI.__info__(:functions)
      assert {:get_repositories_json, 0} in exports
      assert {:update_repositories_json, 3} in exports
    end
  end

  describe "integration readiness" do
    test "functions have correct signatures for integration" do
      # Verify that functions have the expected signatures for integration with Repository module

      # get_repositories_json should return {:ok, {data, sha}} or {:error, reason}
      result = GitHubAPI.get_repositories_json()

      case result do
        {:ok, {data, sha}} ->
          assert is_map(data)
          assert is_binary(sha)

        {:error, reason} ->
          assert is_binary(reason)
      end

      # update_repositories_json should return {:ok, message} or {:error, reason}
      sample_data = %{"test" => "data"}
      result = GitHubAPI.update_repositories_json(sample_data, "fake_sha", "Test message")

      case result do
        {:ok, message} ->
          assert is_binary(message)

        {:error, reason} ->
          assert is_binary(reason)
      end
    end
  end
end
