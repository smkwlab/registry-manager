defmodule RegistryManager.ValidationTest do
  use ExUnit.Case, async: true
  alias RegistryManager.Validation

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
      known_types = ["sotsuron", "wr", "ise-report", "poster", "sotsuron-report", "other"]

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

    test "returns false for sotsuron-report (no draft PR cycle)" do
      assert Validation.default_review_flow("sotsuron-report") == false
    end
  end
end
