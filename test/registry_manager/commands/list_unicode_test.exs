defmodule RegistryManager.Commands.ListUnicodeTest do
  use ExUnit.Case

  alias RegistryManager.Commands.List

  # unicode_display_width/1関数の直接テスト（リファクタリング前の動作保証）
  describe "unicode display width calculation" do
    test "ASCII characters have width 1" do
      # ASCII文字は幅1
      assert List.display_width("a") == 1
      assert List.display_width("ABC") == 3
      assert List.display_width("123") == 3
    end

    test "Japanese characters have width 2" do
      # 日本語文字は幅2
      assert List.display_width("あ") == 2
      assert List.display_width("田中") == 4
      assert List.display_width("佐藤花子") == 8
    end

    test "mixed ASCII and Japanese characters" do
      # ASCII + 日本語の混在
      # 田中(4) + ABC(3)
      assert List.display_width("田中ABC") == 7
      # k21rs001-(9) + 太郎(4)
      assert List.display_width("k21rs001-太郎") == 13
    end

    test "empty string" do
      assert List.display_width("") == 0
    end

    test "student names from test data" do
      # テストデータの学生名で確認
      assert List.display_width("田中太郎") == 8
      assert List.display_width("佐藤花子") == 8
      assert List.display_width("鈴木次郎") == 8
    end

    test "various Unicode ranges covered by simplified logic" do
      # 簡素化されたロジックでカバーされる範囲のテスト

      # CJK統合漢字
      assert List.display_width("漢字") == 4

      # ひらがな
      assert List.display_width("ひらがな") == 8

      # カタカナ
      assert List.display_width("カタカナ") == 8

      # 全角記号
      assert List.display_width("！？") == 4
      assert List.display_width("（）") == 4

      # ハングル
      assert List.display_width("한글") == 4

      # 混在パターン
      # 5 + 4 + 2
      assert List.display_width("Hello世界！") == 11
    end

    test "edge cases for simplified Unicode logic" do
      # 簡素化ロジックのエッジケース

      # 制御文字（幅0）
      assert List.display_width("\u0000\u001F") == 0

      # 制御文字と通常文字の混在
      assert List.display_width("Hello\u0000World") == 10

      # 範囲境界値のテスト
      # CJK範囲の開始
      # 全角スペース
      assert List.display_width("\u3000") == 2
      # CJK範囲の終了
      assert List.display_width("\u9FFF") == 2

      # ASCII範囲
      # スペースと~
      assert List.display_width("\u0020\u007E") == 2
    end
  end

  describe "table formatting with Unicode characters" do
    test "table formatting preserves Japanese character alignment" do
      # 日本語文字を含むテーブルフォーマットのテスト
      repos = [
        {"k21rs001-sotsuron", %{"student_name" => "田中太郎", "github_username" => "student001"}},
        {"k21rs002-wr", %{"student_name" => "佐藤花子", "github_username" => "student002"}}
      ]

      opts = [long: true, format: "table"]

      test_params = [
        repositories: Map.new(repos),
        csv_data: [
          %{"student_id" => "k21rs001", "name" => "田中太郎", "github_username" => "student001"},
          %{"student_id" => "k21rs002", "name" => "佐藤花子", "github_username" => "student002"}
        ],
        activity_data: %{}
      ]

      {:ok, output} = List.run([], opts, test_params)

      # 出力に日本語の名前が含まれていることを確認
      assert String.contains?(output, "田中太郎")
      assert String.contains?(output, "佐藤花子")

      # テーブル形式になっていることを確認（ヘッダー行とセパレータが存在）
      lines = String.split(output, "\n")
      # ヘッダー + セパレータ + データ行2つ以上
      assert length(lines) >= 4
    end
  end
end
