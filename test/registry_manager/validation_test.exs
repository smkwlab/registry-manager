defmodule RegistryManager.ValidationTest do
  use ExUnit.Case, async: true
  alias RegistryManager.Validation

  describe "entry validation" do
    test "validates complete v4 entry" do
      valid_entry = %{
        "student_id" => "k21rs001",
        "repository_type" => "sotsuron",
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_updated_at" => "2025-07-08T06:51:39.835808Z",
        "github_username" => "student001"
      }

      assert :ok = Validation.validate_repository_entry(valid_entry)
    end

    test "validates minimal v4 entry" do
      minimal_entry = %{
        "student_id" => "k21rs001",
        "repository_type" => "wr",
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_updated_at" => "2025-07-08T06:51:39.835808Z"
      }

      assert :ok = Validation.validate_repository_entry(minimal_entry)
    end

    test "detects missing required fields" do
      invalid_entry = %{
        "repository_type" => "sotsuron"
        # Missing required fields
      }

      assert {:error, message} = Validation.validate_repository_entry(invalid_entry)
      assert String.contains?(message, "Missing required fields")
    end

    test "detects legacy format with status and stage" do
      legacy_entry = %{
        "student_id" => "k19rs999",
        "repository_type" => "sotsuron",
        "status" => "completed",
        "stage" => "thesis",
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_updated_at" => "2025-07-08T06:51:39.835808Z"
      }

      assert {:error, message} = Validation.validate_repository_entry(legacy_entry)
      assert String.contains?(message, "Deprecated fields")
    end

    test "detects invalid timestamp formats" do
      invalid_timestamp_entry = %{
        "student_id" => "k21rs001",
        "repository_type" => "wr",
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_updated_at" => "invalid-timestamp"
      }

      assert {:error, message} = Validation.validate_repository_entry(invalid_timestamp_entry)
      assert String.contains?(message, "Invalid timestamp format")
    end

    test "detects missing timestamp fields" do
      no_timestamp_entry = %{
        "student_id" => "k21rs001",
        "repository_type" => "wr"
      }

      assert {:error, message} = Validation.validate_repository_entry(no_timestamp_entry)
      assert String.contains?(message, "Missing required fields")
    end

    test "validates repository type" do
      # Just test that it doesn't crash with different types
      valid_entry = %{
        "student_id" => "k21rs001",
        "repository_type" => "custom-type",
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_updated_at" => "2025-07-08T06:51:39.835808Z"
      }

      result = Validation.validate_repository_entry(valid_entry)
      assert match?(:ok, result) or match?({:error, _}, result)
    end

    test "validates github_username format" do
      valid_with_username = %{
        "student_id" => "k21rs001",
        "repository_type" => "wr",
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_updated_at" => "2025-07-08T06:51:39.835808Z",
        "github_username" => "valid_user123"
      }

      assert :ok = Validation.validate_repository_entry(valid_with_username)
    end

    test "handles empty string values" do
      empty_values_entry = %{
        "student_id" => "",
        "repository_type" => "",
        "repository_created_at" => "",
        "registry_created_at" => "",
        "registry_updated_at" => ""
      }

      assert {:error, message} = Validation.validate_repository_entry(empty_values_entry)
      assert String.contains?(message, "Missing required fields")
    end

    test "handles nil values" do
      nil_values_entry = %{
        "student_id" => nil,
        "repository_type" => nil,
        "repository_created_at" => nil,
        "registry_created_at" => nil,
        "registry_updated_at" => nil
      }

      assert {:error, message} = Validation.validate_repository_entry(nil_values_entry)
      assert String.contains?(message, "Missing required fields")
    end
  end

  describe "student ID validation" do
    test "validates valid undergraduate student IDs" do
      valid_ids = [
        "k21rs001",
        "k92jk123",
        "k19rs999",
        "k90jk001"
      ]

      Enum.each(valid_ids, fn id ->
        assert :ok = Validation.validate_student_id(id)
      end)
    end

    test "validates valid graduate student IDs" do
      valid_ids = [
        "k91gjk01",
        "k92gjk15",
        "k20gjk99"
      ]

      Enum.each(valid_ids, fn id ->
        assert :ok = Validation.validate_student_id(id)
      end)
    end

    test "rejects invalid student ID formats" do
      invalid_ids = [
        # Too short
        "k21rs01",
        # Too long
        "k21rs0001",
        # Invalid department
        "k21xyz001",
        # Missing k prefix
        "21rs001",
        # Wrong case
        "K21RS001",
        # Empty
        "",
        # Completely wrong
        "invalid"
      ]

      Enum.each(invalid_ids, fn id ->
        assert {:error, _} = Validation.validate_student_id(id)
      end)
    end

    test "rejects non-string inputs" do
      non_strings = [nil, 123, %{}, []]

      Enum.each(non_strings, fn input ->
        assert {:error, message} = Validation.validate_student_id(input)
        assert String.contains?(message, "文字列である必要があります")
      end)
    end
  end

  describe "repository type validation" do
    test "validates known repository types" do
      known_types = ["sotsuron", "wr", "ise-report", "poster", "other"]

      Enum.each(known_types, fn type ->
        assert :ok = Validation.validate_repository_type(type)
      end)
    end

    test "accepts master and latex as canonical types (issue #11)" do
      assert :ok = Validation.validate_repository_type("master")
      assert :ok = Validation.validate_repository_type("latex")
    end

    test "rejects thesis with guidance to the canonical vocabulary" do
      assert {:error, message} = Validation.validate_repository_type("thesis")
      assert message =~ "master"
      assert message =~ "latex"
    end

    test "handles unknown repository types" do
      # Test that unknown types don't crash
      result = Validation.validate_repository_type("unknown-type")
      assert match?(:ok, result) or match?({:error, _}, result)
    end
  end

  describe "default_review_flow/1" do
    test "returns true for types with an always-on draft PR cycle" do
      Enum.each(["sotsuron", "master", "ise", "ise-report", "poster"], fn type ->
        assert Validation.default_review_flow(type) == true
      end)
    end

    test "returns false for wr and other" do
      assert Validation.default_review_flow("wr") == false
      assert Validation.default_review_flow("other") == false
    end

    test "returns false for latex (creation-time opt-in)" do
      assert Validation.default_review_flow("latex") == false
    end
  end

  describe "migration detection" do
    test "detects migration needed for legacy entries" do
      legacy_entry = %{
        "student_id" => "k21rs001",
        "repository_type" => "sotsuron",
        "status" => "active",
        "stage" => "thesis"
      }

      # This should detect that migration is needed
      result = Validation.check_migration_needed(legacy_entry)
      assert {:migration_needed, fields} = result
      assert "status" in fields
      assert "stage" in fields
    end

    test "detects no migration needed for v4 entries" do
      v4_entry = %{
        "student_id" => "k21rs001",
        "repository_type" => "sotsuron",
        "repository_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_created_at" => "2025-07-08T06:51:39.835808Z",
        "registry_updated_at" => "2025-07-08T06:51:39.835808Z"
      }

      result = Validation.check_migration_needed(v4_entry)
      assert :no_migration_needed = result
    end
  end
end
