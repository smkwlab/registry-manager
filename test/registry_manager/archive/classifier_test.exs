defmodule RegistryManager.Archive.ClassifierTest do
  use ExUnit.Case, async: true

  alias RegistryManager.Archive.Classifier

  # 名簿エントリ（Repository.load_roster/0 が返す構造を模す）
  defp roster_entry(attrs) do
    Map.merge(
      %{
        student_ids: [],
        name: nil,
        github: nil,
        graduation_year: nil,
        completion_year: nil,
        graduate_student_id: nil
      },
      attrs
    )
  end

  describe "current_nendo/1" do
    test "4月以降はその年が年度" do
      assert Classifier.current_nendo(~D[2026-07-17]) == 2026
      assert Classifier.current_nendo(~D[2026-04-01]) == 2026
    end

    test "1〜3月は前年が年度" do
      assert Classifier.current_nendo(~D[2026-03-31]) == 2025
      assert Classifier.current_nendo(~D[2026-01-05]) == 2025
    end
  end

  describe "classify_all/3 — 卒業判定（卒業年度）" do
    test "卒業年度が現年度より過去なら卒業済み" do
      registry = %{
        "k21rs001-sotsuron" => %{"student_id" => "k21rs001", "repository_type" => "sotsuron"}
      }

      roster = [
        roster_entry(%{student_ids: ["k21rs001"], name: "テスト太郎", graduation_year: "2024"})
      ]

      [result] = Classifier.classify_all(registry, roster, 2026)
      assert result.repo == "k21rs001-sotsuron"
      assert result.classification == :graduated
      assert result.name == "テスト太郎"
      assert result.graduation_year == "2024"
    end

    test "卒業年度が当年度なら在学中（その年の3月に卒業予定）" do
      registry = %{
        "k26rs001-sotsuron" => %{"student_id" => "k26rs001", "repository_type" => "sotsuron"}
      }

      roster = [roster_entry(%{student_ids: ["k26rs001"], graduation_year: "2026"})]

      [result] = Classifier.classify_all(registry, roster, 2026)
      assert result.classification == :enrolled
    end
  end

  describe "classify_all/3 — 修了年度優先" do
    test "修了年度があれば卒業年度より優先して判定する" do
      registry = %{
        "k24gjk01-master" => %{"student_id" => "k24gjk01", "repository_type" => "master"}
      }

      # 卒業年度は過去（学部卒）だが修了年度は当年度 → 修了年度優先で在学中
      roster = [
        roster_entry(%{
          student_ids: ["k24gjk01"],
          graduate_student_id: "k24gjk01",
          graduation_year: "2023",
          completion_year: "2026"
        })
      ]

      [result] = Classifier.classify_all(registry, roster, 2026)
      assert result.classification == :enrolled
    end

    test "修了年度が過去なら卒業済み" do
      registry = %{
        "k22gjk01-master" => %{"student_id" => "k22gjk01", "repository_type" => "master"}
      }

      roster = [
        roster_entry(%{
          student_ids: ["k22gjk01"],
          graduate_student_id: "k22gjk01",
          completion_year: "2024"
        })
      ]

      [result] = Classifier.classify_all(registry, roster, 2026)
      assert result.classification == :graduated
    end
  end

  describe "classify_all/3 — 院進補正" do
    test "大学院学籍番号があり修了年度が空なら在学中（学部卒業年度が過去でも）" do
      # 実例: k26gjk01-wr（学部2025卒だが2026院入学で現役の週報）
      registry = %{"k26gjk01-wr" => %{"student_id" => "k26gjk01", "repository_type" => "wr"}}

      roster = [
        roster_entry(%{
          student_ids: ["k25rs099", "k26gjk01"],
          graduate_student_id: "k26gjk01",
          graduation_year: "2025",
          completion_year: nil
        })
      ]

      [result] = Classifier.classify_all(registry, roster, 2026)
      assert result.classification == :enrolled
      assert result.reason =~ "院"
    end
  end

  describe "classify_all/3 — 特殊学籍（要確認）" do
    test "末尾999はテスト基盤として要確認" do
      registry = %{"k00rs999-wr" => %{"student_id" => "k00rs999", "repository_type" => "wr"}}
      roster = []

      [result] = Classifier.classify_all(registry, roster, 2026)
      assert result.classification == :needs_review
      assert result.reason =~ "特殊学籍"
    end

    test "末尾50xはstaffテスト用として要確認" do
      registry = %{"k00rs501-wr" => %{"student_id" => "k00rs501", "repository_type" => "wr"}}
      roster = []

      [result] = Classifier.classify_all(registry, roster, 2026)
      assert result.classification == :needs_review
      assert result.reason =~ "特殊学籍"
    end
  end

  describe "classify_all/3 — 冪等・未突合・年度なし" do
    test "archived_at 済みは対象外" do
      registry = %{
        "k20rs001-sotsuron" => %{
          "student_id" => "k20rs001",
          "repository_type" => "sotsuron",
          "archived_at" => "2026-07-16T00:00:00Z"
        }
      }

      roster = [roster_entry(%{student_ids: ["k20rs001"], graduation_year: "2023"})]

      [result] = Classifier.classify_all(registry, roster, 2026)
      assert result.classification == :already_archived
    end

    test "名簿と突合できないエントリは要確認" do
      registry = %{"k21rs777-wr" => %{"student_id" => "k21rs777", "repository_type" => "wr"}}
      roster = []

      [result] = Classifier.classify_all(registry, roster, 2026)
      assert result.classification == :needs_review
      assert result.reason =~ "名簿"
    end

    test "年度情報がまったく無い場合は要確認" do
      registry = %{"k21rs001-wr" => %{"student_id" => "k21rs001", "repository_type" => "wr"}}

      roster = [
        roster_entry(%{student_ids: ["k21rs001"], graduation_year: nil, completion_year: nil})
      ]

      [result] = Classifier.classify_all(registry, roster, 2026)
      assert result.classification == :needs_review
    end

    test "末尾に余剰文字を含む不正な年度は年度なしとして扱う（誤って卒業済みにしない）" do
      registry = %{"k21rs001-wr" => %{"student_id" => "k21rs001", "repository_type" => "wr"}}
      roster = [roster_entry(%{student_ids: ["k21rs001"], graduation_year: "2024abc"})]

      [result] = Classifier.classify_all(registry, roster, 2026)
      assert result.classification == :needs_review
    end
  end

  describe "classify_all/3 — 突合キーの正規化" do
    test "学籍番号の大文字小文字・k接頭辞の差異を吸収して突合する" do
      registry = %{"91rs012-wr" => %{"student_id" => "91RS012", "repository_type" => "wr"}}
      roster = [roster_entry(%{student_ids: ["k91rs012"], graduation_year: "2020"})]

      [result] = Classifier.classify_all(registry, roster, 2026)
      assert result.classification == :graduated
    end
  end

  describe "classify_all/3 — 並び・複数件" do
    test "リポジトリ名でソートして全件返す" do
      registry = %{
        "k21rs002-wr" => %{"student_id" => "k21rs002", "repository_type" => "wr"},
        "k21rs001-wr" => %{"student_id" => "k21rs001", "repository_type" => "wr"}
      }

      roster = [
        roster_entry(%{student_ids: ["k21rs001"], graduation_year: "2024"}),
        roster_entry(%{student_ids: ["k21rs002"], graduation_year: "2024"})
      ]

      results = Classifier.classify_all(registry, roster, 2026)
      assert Enum.map(results, & &1.repo) == ["k21rs001-wr", "k21rs002-wr"]
    end
  end
end
