defmodule RegistryManager.Commands.PropagateWorkflowGitTest do
  use ExUnit.Case, async: true

  alias RegistryManager.Commands.PropagateWorkflow

  @moduledoc """
  実際のローカル git リポジトリを使い、PropagateWorkflow の git 連鎖処理
  （propagate_through_all_branches → merge_through_draft_chain → merge_branch →
  run_git_command）を検証する。ネットワークには一切アクセスしない。
  """

  # 各テストで隔離した一時ディレクトリを用意
  setup do
    base = Path.join(System.tmp_dir!(), "pw-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  defp git!(args, cwd) do
    {out, code} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert code == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end

  defp write_and_commit(repo, file, content, message) do
    File.write!(Path.join(repo, file), content)
    git!(["add", file], repo)
    git!(["commit", "-m", message], repo)
  end

  # main が draft ブランチより 1 コミット進んでいる remote + work_dir を構築して返す
  defp setup_repo_with_drafts(base) do
    remote = Path.join(base, "remote.git")
    seed = Path.join(base, "seed")
    File.mkdir_p!(remote)
    File.mkdir_p!(seed)

    git!(["init", "--bare", "--initial-branch=main", "."], remote)

    git!(["init", "--initial-branch=main", "."], seed)
    git!(["config", "user.email", "test@example.com"], seed)
    git!(["config", "user.name", "Test User"], seed)
    git!(["remote", "add", "origin", remote], seed)

    write_and_commit(seed, "README.md", "v1\n", "commit1")
    git!(["push", "-u", "origin", "main"], seed)

    # draft ブランチを commit1 の位置に作成して push
    git!(["branch", "0th-draft"], seed)
    git!(["branch", "1st-draft"], seed)
    git!(["push", "origin", "0th-draft"], seed)
    git!(["push", "origin", "1st-draft"], seed)

    # main を 1 コミット進める（draft より先行させる）
    write_and_commit(seed, "README.md", "v2\n", "commit2")
    git!(["push", "origin", "main"], seed)

    # propagate 対象の作業ディレクトリを clone
    work_dir = Path.join(base, "work")
    git!(["clone", "--quiet", remote, work_dir], base)
    git!(["config", "user.email", "test@example.com"], work_dir)
    git!(["config", "user.name", "Test User"], work_dir)

    %{remote: remote, work_dir: work_dir}
  end

  describe "propagate_through_all_branches/2" do
    test "fast-forwards main through the draft chain and pushes each branch", %{base: base} do
      %{work_dir: work_dir, remote: remote} = setup_repo_with_drafts(base)

      count = PropagateWorkflow.propagate_through_all_branches(work_dir, verbose: false)

      # main→0th-draft, 0th-draft→1st-draft の 2 ペアがマージされる
      assert count == 2

      # remote の各 draft ブランチが main の commit2 を含むこと（v2 が伝播）を確認
      verify = Path.join(base, "verify")
      git!(["clone", "--quiet", remote, verify], base)

      for branch <- ["0th-draft", "1st-draft"] do
        git!(["checkout", branch], verify)
        assert File.read!(Path.join(verify, "README.md")) == "v2\n"
      end
    end

    test "returns 0 when there are no draft branches", %{base: base} do
      remote = Path.join(base, "remote2.git")
      seed = Path.join(base, "seed2")
      File.mkdir_p!(remote)
      File.mkdir_p!(seed)

      git!(["init", "--bare", "--initial-branch=main", "."], remote)
      git!(["init", "--initial-branch=main", "."], seed)
      git!(["config", "user.email", "test@example.com"], seed)
      git!(["config", "user.name", "Test User"], seed)
      git!(["remote", "add", "origin", remote], seed)
      write_and_commit(seed, "README.md", "only-main\n", "commit1")
      git!(["push", "-u", "origin", "main"], seed)

      work_dir = Path.join(base, "work2")
      git!(["clone", "--quiet", remote, work_dir], base)

      assert PropagateWorkflow.propagate_through_all_branches(work_dir, verbose: true) == 0
    end
  end

  describe "run_git_command/2" do
    test "returns {:ok, output} for a successful command", %{base: base} do
      repo = Path.join(base, "r")
      File.mkdir_p!(repo)
      git!(["init", "--initial-branch=main", "."], repo)

      assert {:ok, output} = PropagateWorkflow.run_git_command(["rev-parse", "--git-dir"], repo)
      assert is_binary(output)
    end

    test "returns {:error, output} for a failing command", %{base: base} do
      repo = Path.join(base, "r2")
      File.mkdir_p!(repo)

      # git repository ではないディレクトリで status → 失敗
      assert {:error, output} = PropagateWorkflow.run_git_command(["status"], repo)
      assert is_binary(output)
    end
  end

  describe "parse_draft_branches/1" do
    test "keeps only origin draft branches, sorted numerically" do
      output = """
        origin/HEAD -> origin/main
        origin/main
        origin/2nd-draft
        origin/0th-draft
        origin/10th-draft
        origin/feature-x
      """

      assert PropagateWorkflow.parse_draft_branches(output) == [
               "0th-draft",
               "2nd-draft",
               "10th-draft"
             ]
    end

    test "returns an empty list when there are no draft branches" do
      assert PropagateWorkflow.parse_draft_branches("  origin/main\n  origin/develop") == []
    end
  end

  describe "decode_file_content/2" do
    test "decodes base64 content stripped of newlines" do
      encoded = Base.encode64("hello world")

      response = %{
        "content" => String.slice(encoded, 0, 4) <> "\n" <> String.slice(encoded, 4, 99)
      }

      assert {:ok, "hello world"} = PropagateWorkflow.decode_file_content(response, "any/path")
    end

    test "reports invalid base64 content" do
      response = %{"content" => "!!!not-base64!!!"}

      assert {:error, message} = PropagateWorkflow.decode_file_content(response, "a/b.yml")
      assert message =~ "Invalid Base64 content in a/b.yml"
    end
  end
end
