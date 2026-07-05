defmodule RegistryManager.GitHubAPI.ClientTest do
  use ExUnit.Case, async: true

  alias RegistryManager.GitHubAPI.Client

  describe "not_found_error?/1" do
    test "returns true for 404 error messages from send_request" do
      assert Client.not_found_error?("GitHub API error (404): Not Found")
    end

    test "returns false for other API errors" do
      refute Client.not_found_error?("GitHub API error (401): Bad credentials")
      refute Client.not_found_error?("GitHub API error (500): oops")
      refute Client.not_found_error?("Request failed: :timeout")
    end

    test "returns false for non-binary values" do
      refute Client.not_found_error?(nil)
      refute Client.not_found_error?(:not_found)
    end
  end
end
