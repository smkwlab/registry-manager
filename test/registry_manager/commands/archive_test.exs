defmodule RegistryManager.Commands.ArchiveTest do
  # GitHubAPIMock（Agent 共有状態）に set_mock_response で書き込みを捕捉するため async: false
  use ExUnit.Case, async: false

  alias RegistryManager.Commands.Archive
  alias RegistryManager.Test.GitHubAPIMock

  setup do
    GitHubAPIMock.reset_mock_responses()
    on_exit(fn -> GitHubAPIMock.reset_mock_responses() end)
    :ok
  end

  # k21rs001 = 卒業済み(2024卒), k26gjk01 = 院進で在学中, k00rs999 = 特殊学籍
  defp sample_registry do
    %{
      "k21rs001-sotsuron" => %{"student_id" => "k21rs001", "repository_type" => "sotsuron"},
      "k26gjk01-wr" => %{"student_id" => "k26gjk01", "repository_type" => "wr"},
      "k00rs999-wr" => %{"student_id" => "k00rs999", "repository_type" => "wr"}
    }
  end

  defp sample_roster do
    [
      %{
        student_ids: ["k21rs001"],
        name: "テスト太郎",
        github: "taro",
        graduation_year: "2024",
        completion_year: nil,
        graduate_student_id: nil
      },
      %{
        student_ids: ["k25rs099", "k26gjk01"],
        name: "テスト院生",
        github: "grad",
        graduation_year: "2025",
        completion_year: nil,
        graduate_student_id: "k26gjk01"
      }
    ]
  end

  defp base_params(extra \\ []) do
    Keyword.merge(
      [
        repositories: sample_registry(),
        roster: sample_roster(),
        current_nendo: 2026,
        registry_sha: "test-sha"
      ],
      extra
    )
  end

  describe "validate_options/1" do
    test "デフォルト値を埋める" do
      opts = Archive.validate_options([])
      assert opts[:graduated] == false
      assert opts[:list] == false
      assert opts[:dry_run] == false
      assert opts[:interactive] == false
    end
  end

  describe "run/3 --graduated --list" do
    test "全エントリを判定理由つきで一覧表示し、副作用を起こさない" do
      params = base_params(open_prs: %{"k21rs001-sotsuron" => [%{number: 1, title: "draft"}]})

      # 書き込みが起きたら失敗させる
      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _, _, _ ->
        flunk("--list must not write registry")
      end)

      assert {:ok, output} = Archive.run([], [graduated: true, list: true], params)

      assert output =~ "k21rs001-sotsuron"
      assert output =~ "卒業済み"
      assert output =~ "k26gjk01-wr"
      assert output =~ "在学中"
      assert output =~ "k00rs999-wr"
      assert output =~ "要確認"
    end
  end

  describe "run/3 --graduated --dry-run" do
    test "卒業済み候補のみを実行手順としてシミュレートし、副作用を起こさない" do
      params = base_params(open_prs: %{"k21rs001-sotsuron" => [%{number: 1, title: "draft"}]})

      GitHubAPIMock.set_mock_response(:archive_repository, fn _ ->
        flunk("--dry-run must not archive")
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _, _, _ ->
        flunk("--dry-run must not write registry")
      end)

      assert {:ok, output} = Archive.run([], [graduated: true, dry_run: true], params)

      assert output =~ "DRY-RUN"
      assert output =~ "k21rs001-sotsuron"
      # 在学中・要確認は実行対象に含めない
      refute output =~ "k26gjk01-wr"
    end
  end

  describe "run/3 --graduated 実行" do
    test "卒業済みのみ archive し、archived_at を registry に一括記録する" do
      test_pid = self()

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn new_data, sha, _msg ->
        send(test_pid, {:written, new_data, sha})
        {:ok, "ok"}
      end)

      params = base_params(now: "2026-07-17T00:00:00Z")

      assert {:ok, output} = Archive.run([], [graduated: true], params)
      assert output =~ "k21rs001-sotsuron"

      assert_receive {:written, new_data, "test-sha"}
      assert new_data["k21rs001-sotsuron"]["archived_at"] == "2026-07-17T00:00:00Z"
      # 在学中・特殊学籍は archive されない
      refute Map.has_key?(new_data["k26gjk01-wr"], "archived_at")
      refute Map.has_key?(new_data["k00rs999-wr"], "archived_at")
    end

    test "要確認は実行せず、末尾に一覧報告する" do
      params = base_params()
      assert {:ok, output} = Archive.run([], [graduated: true], params)
      assert output =~ "要確認" or output =~ "スキップ"
      assert output =~ "k00rs999-wr"
    end

    test "個別 archive の失敗では中断せず、全体としてエラーを返す" do
      params = base_params(mock_archive: {:error, "archive failed"})

      assert {:error, output} = Archive.run([], [graduated: true], params)
      assert output =~ "archive failed" or output =~ "❌"
    end

    test "open PR 一覧の取得に失敗したら archive せずエラーを返す" do
      # open PR を取得できないまま archive すると PR を閉じ残すため、失敗を伝播させる
      GitHubAPIMock.set_mock_response(:list_open_pull_requests, fn _repo ->
        {:error, "API rate limit"}
      end)

      GitHubAPIMock.set_mock_response(:archive_repository, fn _repo ->
        flunk("must not archive when PR listing failed")
      end)

      # open_prs を注入しない（実 API 経路 = モックのエラーを通す）
      params = [
        repositories: sample_registry(),
        roster: sample_roster(),
        current_nendo: 2026,
        registry_sha: "test-sha"
      ]

      assert {:error, output} = Archive.run([], [graduated: true], params)
      assert output =~ "API rate limit"
    end
  end

  describe "run/3 --graduated -i (interactive)" do
    # 対話候補は「卒業済み(k21rs001-sotsuron)」と「要確認(k00rs999-wr)」の 2 件。
    # 在学中(k26gjk01-wr)は対話でも提示しない。応答は test_params[:inputs] で注入する。

    defp interactive_params(inputs, extra \\ []) do
      test_pid = self()

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn new_data, sha, _msg ->
        send(test_pid, {:written, new_data, sha})
        {:ok, "ok"}
      end)

      base_params(
        [
          mock_archive: true,
          open_prs: %{},
          now: "2026-07-17T00:00:00Z",
          interactive: true,
          inputs: inputs
        ] ++ extra
      )
    end

    test "全 y で卒業済み・要確認の両方を archive する" do
      params = interactive_params(["y", "y"])

      assert {:ok, output} = Archive.run([], [graduated: true, interactive: true], params)
      assert output =~ "k21rs001-sotsuron"

      assert_receive {:written, new_data, "test-sha"}
      assert new_data["k21rs001-sotsuron"]["archived_at"] == "2026-07-17T00:00:00Z"
      assert new_data["k00rs999-wr"]["archived_at"] == "2026-07-17T00:00:00Z"
      # 在学中は対象外
      refute Map.has_key?(new_data["k26gjk01-wr"], "archived_at")
    end

    test "y と n の混在では y の候補だけ archive する" do
      params = interactive_params(["y", "n"])

      assert {:ok, _output} = Archive.run([], [graduated: true, interactive: true], params)

      assert_receive {:written, new_data, _sha}
      assert new_data["k21rs001-sotsuron"]["archived_at"] == "2026-07-17T00:00:00Z"
      refute Map.has_key?(new_data["k00rs999-wr"], "archived_at")
    end

    test "n で卒業済みをスキップし、y で要確認を archive できる" do
      params = interactive_params(["n", "y"])

      assert {:ok, _output} = Archive.run([], [graduated: true, interactive: true], params)

      assert_receive {:written, new_data, _sha}
      refute Map.has_key?(new_data["k21rs001-sotsuron"], "archived_at")
      assert new_data["k00rs999-wr"]["archived_at"] == "2026-07-17T00:00:00Z"
    end

    test "a で以降すべてを確認なしに archive する" do
      params = interactive_params(["a"])

      assert {:ok, _output} = Archive.run([], [graduated: true, interactive: true], params)

      assert_receive {:written, new_data, _sha}
      assert new_data["k21rs001-sotsuron"]["archived_at"] == "2026-07-17T00:00:00Z"
      assert new_data["k00rs999-wr"]["archived_at"] == "2026-07-17T00:00:00Z"
    end

    test "q で中断し、以降は archive せず registry も書き込まない" do
      # 1 件目で中断 → 実行 0 件 → 書き込みなし
      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _, _, _ ->
        flunk("q で中断した場合は registry を書き込まない")
      end)

      params =
        base_params(
          mock_archive: true,
          open_prs: %{},
          interactive: true,
          inputs: ["q"]
        )

      assert {:ok, output} = Archive.run([], [graduated: true, interactive: true], params)
      assert output =~ "中断" or output =~ "archive 対象がありませんでした"
    end

    test "q で中断する前に y で archive した分は記録される" do
      params = interactive_params(["y", "q"])

      assert {:ok, _output} = Archive.run([], [graduated: true, interactive: true], params)

      assert_receive {:written, new_data, _sha}
      assert new_data["k21rs001-sotsuron"]["archived_at"] == "2026-07-17T00:00:00Z"
      refute Map.has_key?(new_data["k00rs999-wr"], "archived_at")
    end

    test "入力が尽きたら中断として扱い、書き込まない" do
      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _, _, _ ->
        flunk("入力が尽きたら registry を書き込まない")
      end)

      params =
        base_params(
          mock_archive: true,
          open_prs: %{},
          interactive: true,
          inputs: []
        )

      assert {:ok, _output} = Archive.run([], [graduated: true, interactive: true], params)
    end

    test "無効な入力は再プロンプトし、次の有効な応答で判定する" do
      params = interactive_params(["x", "y", "n"])

      assert {:ok, _output} = Archive.run([], [graduated: true, interactive: true], params)

      assert_receive {:written, new_data, _sha}
      # "x"(無効)→再入力"y" で 1 件目 archive、"n" で 2 件目スキップ
      assert new_data["k21rs001-sotsuron"]["archived_at"] == "2026-07-17T00:00:00Z"
      refute Map.has_key?(new_data["k00rs999-wr"], "archived_at")
    end

    test "提示・表示順は卒業済み→要確認で決定的" do
      params = interactive_params(["y", "y"])

      assert {:ok, output} = Archive.run([], [graduated: true, interactive: true], params)

      # 卒業済み(k21rs001-sotsuron)が要確認(k00rs999-wr)より前に表示される
      graduated_pos = :binary.match(output, "k21rs001-sotsuron") |> elem(0)
      review_pos = :binary.match(output, "k00rs999-wr") |> elem(0)
      assert graduated_pos < review_pos
    end
  end

  describe "run/3 単発 archive <repo>" do
    test "指定リポジトリを archive し archived_at を記録する" do
      test_pid = self()

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn new_data, _sha, _msg ->
        send(test_pid, {:written, new_data})
        {:ok, "ok"}
      end)

      params = [
        repositories: sample_registry(),
        registry_sha: "test-sha",
        now: "2026-07-17T00:00:00Z"
      ]

      assert {:ok, output} = Archive.run(["k26gjk01-wr"], [], params)
      assert output =~ "k26gjk01-wr"

      assert_receive {:written, new_data}
      assert new_data["k26gjk01-wr"]["archived_at"] == "2026-07-17T00:00:00Z"
    end

    test "--dry-run では実行せずシミュレーション表示し、副作用を起こさない" do
      GitHubAPIMock.set_mock_response(:archive_repository, fn _ ->
        flunk("single --dry-run must not archive")
      end)

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _, _, _ ->
        flunk("single --dry-run must not write registry")
      end)

      params = [repositories: sample_registry(), registry_sha: "test-sha"]

      assert {:ok, output} = Archive.run(["k26gjk01-wr"], [dry_run: true], params)
      assert output =~ "DRY-RUN"
      assert output =~ "k26gjk01-wr"
    end

    test "registry 未登録のリポジトリはエラー" do
      params = [repositories: sample_registry(), registry_sha: "test-sha"]
      assert {:error, reason} = Archive.run(["k99zz999-wr"], [], params)
      assert reason =~ "registry"
    end

    test "既に archive 済みなら冪等にスキップ（書き込まない）" do
      registry =
        Map.put(sample_registry(), "k21rs001-sotsuron", %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "archived_at" => "2026-07-16T00:00:00Z"
        })

      GitHubAPIMock.set_mock_response(:update_repositories_json, fn _, _, _ ->
        flunk("already archived repo must not be written again")
      end)

      params = [repositories: registry, registry_sha: "test-sha"]
      assert {:ok, output} = Archive.run(["k21rs001-sotsuron"], [], params)
      assert output =~ "archive" or output =~ "済み"
    end
  end
end
