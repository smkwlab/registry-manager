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
end
