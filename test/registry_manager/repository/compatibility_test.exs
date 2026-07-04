defmodule RegistryManager.Repository.CompatibilityTest do
  use ExUnit.Case, async: true

  alias RegistryManager.Repository.Compatibility

  describe "normalize_github_username/1" do
    test "converts single string to array" do
      assert Compatibility.normalize_github_username("user1") == ["user1"]
    end

    test "returns array as-is" do
      assert Compatibility.normalize_github_username(["user1", "user2"]) == ["user1", "user2"]
    end

    test "handles nil" do
      assert Compatibility.normalize_github_username(nil) == []
    end

    test "handles empty string" do
      assert Compatibility.normalize_github_username("") == []
    end

    test "filters out non-string values from array" do
      assert Compatibility.normalize_github_username(["user1", 123, nil, "user2"]) == [
               "user1",
               "user2"
             ]
    end

    test "removes whitespace and empty strings" do
      assert Compatibility.normalize_github_username(["  user1  ", "", "user2"]) == [
               "user1",
               "user2"
             ]
    end

    test "removes duplicates" do
      assert Compatibility.normalize_github_username(["user1", "user2", "user1"]) == [
               "user1",
               "user2"
             ]
    end
  end

  describe "normalize_repository_data/1" do
    test "normalizes string github_username to array" do
      repo_data = %{"github_username" => "user1", "student_id" => "k21rs001"}
      expected = %{"github_username" => ["user1"], "student_id" => "k21rs001"}

      assert Compatibility.normalize_repository_data(repo_data) == expected
    end

    test "leaves array github_username as-is" do
      repo_data = %{"github_username" => ["user1", "user2"], "student_id" => "k21rs001"}

      assert Compatibility.normalize_repository_data(repo_data) == repo_data
    end

    test "removes empty github_username field" do
      repo_data = %{"github_username" => "", "student_id" => "k21rs001"}
      expected = %{"student_id" => "k21rs001"}

      assert Compatibility.normalize_repository_data(repo_data) == expected
    end

    test "handles missing github_username field" do
      repo_data = %{"student_id" => "k21rs001"}

      assert Compatibility.normalize_repository_data(repo_data) == repo_data
    end
  end

  describe "get_primary_github_username/1" do
    test "returns first username from array" do
      repo_data = %{"github_username" => ["user1", "user2"]}

      assert Compatibility.get_primary_github_username(repo_data) == "user1"
    end

    test "returns string username directly" do
      repo_data = %{"github_username" => "user1"}

      assert Compatibility.get_primary_github_username(repo_data) == "user1"
    end

    test "returns nil for empty array" do
      repo_data = %{"github_username" => []}

      assert Compatibility.get_primary_github_username(repo_data) == nil
    end

    test "returns nil for missing field" do
      repo_data = %{"student_id" => "k21rs001"}

      assert Compatibility.get_primary_github_username(repo_data) == nil
    end
  end

  describe "get_all_github_usernames/1" do
    test "returns all usernames from array" do
      repo_data = %{"github_username" => ["user1", "user2"]}

      assert Compatibility.get_all_github_usernames(repo_data) == ["user1", "user2"]
    end

    test "converts string to array" do
      repo_data = %{"github_username" => "user1"}

      assert Compatibility.get_all_github_usernames(repo_data) == ["user1"]
    end

    test "returns empty array for missing field" do
      repo_data = %{"student_id" => "k21rs001"}

      assert Compatibility.get_all_github_usernames(repo_data) == []
    end
  end

  describe "add_github_username/2" do
    test "adds username to empty field" do
      repo_data = %{"student_id" => "k21rs001"}
      expected = %{"student_id" => "k21rs001", "github_username" => ["newuser"]}

      assert Compatibility.add_github_username(repo_data, "newuser") == expected
    end

    test "adds username to existing single user" do
      repo_data = %{"github_username" => "user1"}
      expected = %{"github_username" => ["user1", "user2"]}

      assert Compatibility.add_github_username(repo_data, "user2") == expected
    end

    test "adds username to existing array" do
      repo_data = %{"github_username" => ["user1", "user2"]}
      expected = %{"github_username" => ["user1", "user2", "user3"]}

      assert Compatibility.add_github_username(repo_data, "user3") == expected
    end

    test "does not add duplicate username" do
      repo_data = %{"github_username" => ["user1", "user2"]}

      assert Compatibility.add_github_username(repo_data, "user1") == repo_data
    end

    test "ignores empty username" do
      repo_data = %{"github_username" => ["user1"]}

      assert Compatibility.add_github_username(repo_data, "") == repo_data
    end
  end

  describe "remove_github_username/2" do
    test "removes username from array" do
      repo_data = %{"github_username" => ["user1", "user2", "user3"]}
      expected = %{"github_username" => ["user1", "user3"]}

      assert Compatibility.remove_github_username(repo_data, "user2") == expected
    end

    test "removes last username and deletes field" do
      repo_data = %{"github_username" => ["user1"], "student_id" => "k21rs001"}
      expected = %{"student_id" => "k21rs001"}

      assert Compatibility.remove_github_username(repo_data, "user1") == expected
    end

    test "handles removing non-existent username" do
      repo_data = %{"github_username" => ["user1", "user2"]}

      assert Compatibility.remove_github_username(repo_data, "user3") == repo_data
    end
  end

  describe "set_github_usernames/2" do
    test "sets multiple usernames" do
      repo_data = %{"github_username" => "olduser", "student_id" => "k21rs001"}
      expected = %{"github_username" => ["user1", "user2"], "student_id" => "k21rs001"}

      assert Compatibility.set_github_usernames(repo_data, ["user1", "user2"]) == expected
    end

    test "removes field when setting empty array" do
      repo_data = %{"github_username" => ["user1"], "student_id" => "k21rs001"}
      expected = %{"student_id" => "k21rs001"}

      assert Compatibility.set_github_usernames(repo_data, []) == expected
    end

    test "normalizes input array" do
      repo_data = %{"student_id" => "k21rs001"}
      expected = %{"github_username" => ["user1", "user2"], "student_id" => "k21rs001"}

      assert Compatibility.set_github_usernames(repo_data, ["user1", "", "user2", "user1"]) ==
               expected
    end
  end
end
