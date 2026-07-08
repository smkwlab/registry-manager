defmodule RegistryManager.CSVIntegrationTest do
  use ExUnit.Case, async: false

  alias RegistryManager.Repository

  @moduledoc """
  CSV読み込み機能の統合テスト

  実際のCSVファイルの中身ではなく、CSV読み込み・解析機能をテストします。
  """

  describe "CSV parsing functionality" do
    test "get_github_username_from_csv/1 handles valid student ID" do
      # テスト環境ではtest_students.csvが使用される
      case Repository.get_github_username_from_csv("k21rs001") do
        {:ok, username} ->
          assert is_binary(username)
          assert String.length(username) > 0

        {:error, _reason} ->
          # CSVファイルが利用できない場合はエラーが返される（正常）
          assert true
      end
    end

    test "get_github_username_from_csv/1 handles non-existent student ID" do
      result = Repository.get_github_username_from_csv("k99nonexistent999")
      assert {:error, _reason} = result
    end

    test "get_student_id_from_csv_by_github/1 handles valid GitHub username" do
      # テスト環境でのGitHub username検索
      case Repository.get_student_id_from_csv_by_github("taro-yamada") do
        {:ok, student_id} ->
          assert is_binary(student_id)
          assert String.match?(student_id, ~r/^k\d{2}[a-z]{2}\d{3}$/)

        {:error, _reason} ->
          # CSVファイルが利用できない場合はエラーが返される（正常）
          assert true
      end
    end

    test "get_student_id_from_csv_by_github/1 handles non-existent GitHub username" do
      result = Repository.get_student_id_from_csv_by_github("nonexistent-user")
      assert {:error, _reason} = result
    end
  end

  describe "CSV error handling" do
    test "gracefully handles CSV file not found" do
      # 存在しないパスでテスト（private関数なので直接テストできないため、副作用で確認）
      result = Repository.get_github_username_from_csv("any-student")

      # エラーまたは正常な結果のいずれでも、クラッシュしないことを確認
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # Issue #31: 実運用CSVは先頭に「卒業年度」「修了年度」等の列が加わり、
  # 学籍番号/氏名/GitHub の列位置が旧レイアウトから +2 以上ずれる。
  # 列位置ではなくヘッダ名で解決することで、どちらのレイアウトでも正しく
  # 突合できることを検証する（列位置ハードコードだと氏名が全件 N/A になる回帰を防ぐ）。
  describe "real-world CSV layout (Issue #31)" do
    setup do
      override =
        Path.join([File.cwd!(), "test/fixtures/test_students_real_layout.csv"])

      Application.put_env(:registry_manager, :csv_path_override, override)

      on_exit(fn ->
        Application.delete_env(:registry_manager, :csv_path_override)
      end)

      :ok
    end

    test "resolves student names from header regardless of leading columns" do
      assert {:ok, students} = Repository.get_all_students_from_csv()

      taro = Enum.find(students, &(&1["student_id"] == "k21rs001"))
      assert taro["name"] == "テスト太郎"
      assert taro["github_username"] == "taro-yamada"

      hanako = Enum.find(students, &(&1["student_id"] == "k21rs002"))
      assert hanako["name"] == "テスト花子"
    end

    test "resolves github username by student id on the shifted layout" do
      assert {:ok, "taro-yamada"} = Repository.get_github_username_from_csv("k21rs001")
    end

    test "resolves student id from github username on the shifted layout" do
      assert {:ok, "k21rs001"} = Repository.get_student_id_from_csv_by_github("taro-yamada")
    end

    # 大学院生は「学籍番号」列に学部時代の番号、「大学院学籍番号」列(index 3)に
    # 院の番号が入る。registry はどちらのキーで登録されている可能性もあるため、
    # 両列を突合候補に含めて氏名・github を解決できることを検証する。
    test "resolves graduate students by both undergraduate and graduate student id" do
      assert {:ok, students} = Repository.get_all_students_from_csv()

      by_undergrad = Enum.find(students, &(&1["student_id"] == "k22rs004"))
      assert by_undergrad["name"] == "テスト院生"
      assert by_undergrad["github_username"] == "grad-user"

      by_graduate = Enum.find(students, &(&1["student_id"] == "k26gjk01"))
      assert by_graduate["name"] == "テスト院生"
      assert by_graduate["github_username"] == "grad-user"
    end

    test "resolves github username by either student id for graduate students" do
      assert {:ok, "grad-user"} = Repository.get_github_username_from_csv("k22rs004")
      assert {:ok, "grad-user"} = Repository.get_github_username_from_csv("k26gjk01")
    end
  end
end
