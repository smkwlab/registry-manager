defmodule RegistryManager.CLI do
  @moduledoc """
  CLI interface for registry manager
  """

  alias RegistryManager.Commands.Cache
  alias RegistryManager.Commands.Edit
  alias RegistryManager.Commands.InferStudentId
  alias RegistryManager.Commands.List
  alias RegistryManager.Commands.Migrate
  alias RegistryManager.Commands.PropagateWorkflow
  alias RegistryManager.Commands.PrStatus
  alias RegistryManager.Repository

  # テスト用の関数（通常時は System.halt と IO.puts を使用）
  @spec exit_with_code(integer()) :: no_return()
  defp exit_with_code(code) do
    if Application.get_env(:registry_manager, :test_mode, false) do
      throw({:cli_test_exit, code})
    else
      System.halt(code)
    end
  end

  defp print_output(message) do
    if Application.get_env(:registry_manager, :test_mode, false) do
      current_output = Application.get_env(:registry_manager, :test_output, "")
      new_output = current_output <> message <> "\n"
      Application.put_env(:registry_manager, :test_output, new_output)
    else
      IO.puts(message)
    end
  end

  @spec main([String.t()]) :: no_return()
  def main(args) do
    args
    |> parse_args()
    |> process()
  end

  @doc false
  @spec process(any()) :: no_return()
  def process(parsed_command), do: process_impl(parsed_command)

  @doc false
  def parse_args(args) do
    {opts, argv, _} =
      OptionParser.parse(args,
        strict: [
          help: :boolean,
          dry_run: :boolean,
          verbose: :boolean,
          delete_github_repo: :boolean,
          force: :boolean,
          show_type: :boolean,
          show_protection: :boolean,
          no_names: :boolean,
          long: :boolean,
          activity: :boolean,
          owner_activity: :boolean,
          show_registry_updated: :boolean,
          show_both_timestamps: :boolean,
          no_cache: :boolean,
          format: :string,
          type: :string,
          sort_by_time: :boolean,
          reverse: :boolean,
          show_student_id: :boolean,
          add_owner: :string,
          remove_owner: :string,
          set_owners: :string,
          state: :string,
          include_reviews: :boolean,
          show_activity: :boolean,
          review_requested: :boolean,
          sort: :string,
          all: :boolean,
          from_template: :boolean
        ],
        aliases: [
          h: :help,
          d: :dry_run,
          v: :verbose,
          f: :force,
          T: :type,
          l: :long,
          a: :activity,
          o: :owner_activity,
          t: :sort_by_time,
          r: :reverse,
          s: :show_student_id,
          p: :show_protection
        ]
      )

    if opts[:help] do
      :help
    else
      parse_command(argv, opts)
    end
  end

  @doc false
  def parse_command(argv, opts) do
    case normalize_command(argv) do
      {command, args} ->
        case command_parser_map()[command] do
          nil -> :help
          parser_fun -> parser_fun.(args, opts)
        end

      _ ->
        :help
    end
  end

  # コマンドエイリアスの正規化
  defp normalize_command(["rm" | args]), do: {"remove", args}
  defp normalize_command(["ls" | args]), do: {"list", args}
  defp normalize_command(["cache-status" | _]), do: {"cache-alias", ["status"]}
  defp normalize_command(["cache-clear" | _]), do: {"cache-alias", ["clear"]}
  defp normalize_command(["cache-refresh" | _]), do: {"cache-alias", ["refresh"]}
  defp normalize_command([command | args]), do: {command, args}
  defp normalize_command(_), do: nil

  # コマンド → パーサー関数のマッピング
  defp command_parser_map do
    %{
      "add" => &parse_add_command/2,
      "update" => &parse_update_command/2,
      "remove" => &parse_remove_command/2,
      "protect" => &parse_protect_command/2,
      "list" => &parse_list_command/2,
      "validate" => &parse_validate_command/2,
      "migrate" => &parse_migrate_command/2,
      "cache" => &parse_cache_command/2,
      "cache-alias" => &parse_cache_alias/2,
      "infer-student-id" => &parse_infer_student_id_command/2,
      "edit" => &parse_edit_command/2,
      "pr-status" => &parse_pr_status_command/2,
      "propagate-workflow" => &parse_propagate_workflow_command/2
    }
  end

  # cache-*エイリアス専用パーサー
  defp parse_cache_alias([command], opts) do
    parse_cache_command_alias(command, opts)
  end

  defp parse_add_command([repo_name], opts) do
    {:add_auto, repo_name, opts}
  end

  defp parse_add_command([repo_name, student_id, repo_type], opts) do
    {:add_explicit, {repo_name, student_id, repo_type}, opts}
  end

  defp parse_add_command([_repo_name, _student_id, _repo_type, _status | _stage], _opts) do
    {:error, "旧形式のadd コマンドは廃止されました。新形式を使用してください: add <repo_name> <student_id> <repo_type>"}
  end

  defp parse_add_command(_, _opts), do: :help

  defp parse_update_command([repo_name, field, value], opts) do
    {:update, {repo_name, field, value}, opts}
  end

  defp parse_update_command(_, _opts), do: :help

  defp parse_remove_command([repo_name], opts) do
    {:remove, repo_name, opts}
  end

  defp parse_remove_command(_, _opts), do: :help

  defp parse_protect_command([repo_name], opts) do
    {:protect, repo_name, opts}
  end

  defp parse_protect_command(_, _opts), do: :help

  defp parse_list_command([], opts), do: {:list, nil, opts}
  defp parse_list_command([filter], opts), do: {:list, filter, opts}
  defp parse_list_command(_, _opts), do: :help

  defp parse_validate_command([], opts), do: {:validate, nil, opts}
  defp parse_validate_command(_, _opts), do: :help

  defp parse_migrate_command([], opts), do: {:migrate, [], opts}
  defp parse_migrate_command([subcommand], opts), do: {:migrate, [subcommand], opts}
  defp parse_migrate_command(_, _opts), do: :help

  defp parse_cache_command([subcommand], opts), do: {:cache, [subcommand], opts}
  defp parse_cache_command([], opts), do: {:cache, [], opts}
  defp parse_cache_command(_, _opts), do: :help

  defp parse_cache_command_alias(subcommand, opts) do
    parse_cache_command([subcommand], opts)
  end

  defp parse_infer_student_id_command([repo_name], opts) do
    {:infer_student_id, repo_name, opts}
  end

  defp parse_infer_student_id_command(_, _opts), do: :help

  defp parse_edit_command([repo_name], opts) do
    {:edit, repo_name, opts}
  end

  defp parse_edit_command(_, _opts), do: :help

  defp parse_pr_status_command([], opts), do: {:pr_status, nil, opts}
  defp parse_pr_status_command([filter], opts), do: {:pr_status, filter, opts}
  defp parse_pr_status_command(_, _opts), do: :help

  defp parse_propagate_workflow_command([], opts) do
    if opts[:all] do
      {:propagate_workflow, [], opts}
    else
      :help
    end
  end

  defp parse_propagate_workflow_command([repo_name], opts), do: {:propagate_workflow, [repo_name], opts}
  defp parse_propagate_workflow_command(_, _opts), do: :help

  @spec process_impl(any()) :: no_return()
  defp process_impl(:help) do
    print_output("""
    registry-manager - thesis-student-registry 管理ツール

    使用方法:
      registry-manager <command> [options]

    コマンド:
      add <repo_name>
          リポジトリ情報を新規登録（推論形式・推奨）
          GitHub APIからリポジトリ情報を取得し、CSVから学生IDを特定
      
      add <repo_name> <student_id> <repo_type>
          リポジトリ情報を新規登録（明示的形式）
      
      add <repo_name> <student_id> <repo_type> <status> [stage]
          リポジトリ情報を新規登録（旧形式・非推奨）

      update <repo_name> <field> <value>
          既存リポジトリ情報を更新

      remove <repo_name>
          リポジトリ情報をレジストリから削除

      protect <repo_name>
          ブランチ保護設定完了をマーク

      list [filter] (エイリアス: ls)
          リポジトリ一覧・状況を表示

      pr-status [filter]
          各リポジトリのPull Request状態を表示
          --format table|csv|json : 出力形式
          --type wr|ise|sotsuron : リポジトリタイプフィルタ
          --state open|closed|all : PR状態フィルタ
          --review-requested : 保留中のレビューリクエストがあるPRのみ表示
          --sort repository|updated|created : ソート順（デフォルト: repository）
          --reverse : ソート順を反転

      propagate-workflow <repo_name>
          ワークフロー更新をドラフトブランチ階層に伝播
          main → 0th-draft → 1st-draft → ... の順でマージ
          --all : 全リポジトリを処理
          --type wr|ise|sotsuron|thesis : リポジトリタイプフィルタ
          --from-template : テンプレートから最新ワークフローを適用してから伝播
          --dry-run : 実行せずに確認のみ

      validate
          全データの整合性を検証

      migrate [status|dry-run|execute]
          レジストリデータをv1からv4形式に移行

      infer-student-id <repo_name>
          github_usernameからCSVを元に学生IDを推論して設定

      edit <repo_name>
          リポジトリのGitHubオーナーを編集
          --add-owner <username>      オーナーを追加
          --remove-owner <username>   オーナーを削除
          --set-owners <user1,user2>  オーナーを設定（カンマ区切り）

    オプション:
      -d, --dry-run               実際の変更を行わない
      -v, --verbose               詳細ログを表示
      --delete-github-repo        GitHubリポジトリも削除（removeコマンドのみ）
      -f, --force                 確認をスキップ（危険な操作時）
      -l, --long                  詳細テーブル表示（listコマンド）
      --show-type                 リポジトリタイプ列を表示（listコマンド）
      --show-protection           保護状態列を表示（listコマンド）
      --no-names                  学生名を非表示（listコマンド）
      -a, --activity              リポジトリの最終活動時刻を取得表示（listコマンド）
      -o, --owner-activity        リポジトリオーナーの活動時刻を取得表示（listコマンド）
      --format table|csv|json     出力形式を指定（listコマンド）
      -T, --type TYPE             リポジトリタイプでフィルタ（listコマンド）
      -t, --sort-by-time          時刻でソート（新しい順）（listコマンド）
      -r, --reverse               ソート順を逆にする（listコマンド）
      -s, --show-student-id       学生IDを表示（listコマンド）
      --no-cache                  キャッシュを使用しない（listコマンド）
                                  例: wr, ise-report, sotsuron
      -h, --help                  このヘルプを表示

    例:
      registry-manager add k21rs001-sotsuron  # 推論形式（推奨）
      registry-manager add smkwlab/k21rs001-wr  # org/repo形式も対応
      registry-manager add k21rs001-sotsuron k21rs001 sotsuron  # 明示的形式
      registry-manager add k21rs001-sotsuron k21rs001 sotsuron active thesis  # 非推奨
      registry-manager update k21rs001-sotsuron status completed
      registry-manager remove k21rs001-sotsuron
      registry-manager remove k21rs001-sotsuron --delete-github-repo --force
      registry-manager protect k21rs001-sotsuron
      registry-manager list
      registry-manager list --long
      registry-manager list --type wr --long
      registry-manager list --activity --type sotsuron --long
      registry-manager list --format csv
      registry-manager list active
      registry-manager validate
      registry-manager migrate status  # 移行が必要なエントリを確認
      registry-manager migrate dry-run  # 移行のシミュレーション実行
      registry-manager migrate execute  # 実際の移行を実行
      registry-manager infer-student-id 91rs044-wr  # github_usernameから学生IDを推論
      registry-manager infer-student-id demouser-wr --dry-run  # ドライランで確認
      registry-manager propagate-workflow k92rs001-sotsuron  # 単一リポジトリ
      registry-manager propagate-workflow --all --type thesis  # 全論文リポジトリ
      registry-manager propagate-workflow --all --type thesis --dry-run  # 確認のみ
      registry-manager propagate-workflow --all --type thesis --from-template  # テンプレートから適用
    """)

    exit_with_code(0)
  end

  defp process_impl({:add_auto, repo_name, opts}) do
    if opts[:verbose] do
      print_output("GitHub APIから情報を取得中: #{repo_name}")
    end

    case Repository.add_with_inference(repo_name, opts) do
      {:ok, message} ->
        print_output("✅ #{message}")
        exit_with_code(0)

      {:error, "Cannot determine student ID for " <> github_id} ->
        print_output("❌ 学生IDを特定できませんでした。")
        print_output("  - リポジトリ作成者: #{github_id}")
        print_output("  - このGitHub IDがCSVファイルに登録されていません。")
        print_output("  - リポジトリ名が標準形式（k21rs001-sotsuron）ではありません。")
        print_output("")
        print_output("  完全な形式を使用してください: add <repo_name> <student_id> <repo_type>")
        exit_with_code(1)

      {:error, "Cannot determine student ID"} ->
        print_output("❌ 学生IDを特定できませんでした。")
        print_output("  - リポジトリ作成者のGitHub IDがCSVファイルに登録されていません。")
        print_output("  - リポジトリ名が標準形式（k21rs001-sotsuron）ではありません。")
        print_output("")
        print_output("  完全な形式を使用してください: add <repo_name> <student_id> <repo_type>")
        exit_with_code(1)

      {:error, "Cannot infer repository type"} ->
        print_output("❌ リポジトリタイプを推論できません")
        print_output("リポジトリ名に -sotsuron, -wr, -ise などを含めてください")
        print_output("完全な形式を使用してください: add <repo_name> <student_id> <repo_type>")
        exit_with_code(1)

      {:error, reason} ->
        print_output("❌ エラー: #{reason}")
        exit_with_code(1)
    end
  end

  defp process_impl({:add_explicit, {repo_name, student_id, repo_type}, opts}) do
    if opts[:verbose], do: print_output("リポジトリ情報を追加中（明示的指定）: #{repo_name}")

    case Repository.add(repo_name, student_id, repo_type, opts) do
      {:ok, message} ->
        print_output("✅ #{message}")
        exit_with_code(0)

      {:error, reason} ->
        print_output("❌ エラー: #{reason}")
        exit_with_code(1)
    end
  end

  defp process_impl({:update, {repo_name, field, value}, opts}) do
    if opts[:verbose], do: print_output("リポジトリ情報を更新中: #{repo_name} (#{field} = #{value})")

    case Repository.update(repo_name, field, value, opts) do
      {:ok, message} ->
        print_output("✅ #{message}")
        exit_with_code(0)

      {:error, reason} ->
        print_output("❌ エラー: #{reason}")
        exit_with_code(1)
    end
  end

  defp process_impl({:remove, repo_name, opts}) do
    if opts[:verbose], do: print_output("リポジトリ情報を削除中: #{repo_name}")

    case Repository.remove(repo_name, opts) do
      {:ok, message} ->
        print_output("✅ #{message}")
        exit_with_code(0)

      {:error, reason} ->
        print_output("❌ エラー: #{reason}")
        exit_with_code(1)
    end
  end

  defp process_impl({:protect, repo_name, opts}) do
    if opts[:verbose], do: print_output("ブランチ保護設定完了をマーク: #{repo_name}")

    case Repository.mark_protected(repo_name, opts) do
      {:ok, message} ->
        print_output("✅ #{message}")
        exit_with_code(0)

      {:error, reason} ->
        print_output("❌ エラー: #{reason}")
        exit_with_code(1)
    end
  end

  defp process_impl({:list, filter, opts}) do
    # フィルターがある場合はオプションに追加
    opts = if filter, do: Keyword.put(opts, :type, filter), else: opts

    case List.run([], opts) do
      {:ok, output} ->
        print_output(output)
        exit_with_code(0)

      {:error, reason} ->
        print_output("❌ エラー: #{reason}")
        exit_with_code(1)
    end
  end

  defp process_impl({:validate, _, opts}) do
    if opts[:verbose], do: print_output("データ整合性検証を開始...")

    case Repository.validate_all_data(opts) do
      {:ok, output} ->
        print_output(output)
        exit_with_code(0)

      {:error, reason} ->
        print_output("❌ 検証エラー: #{reason}")
        exit_with_code(1)
    end
  end

  defp process_impl({:migrate, args, opts}) do
    if opts[:verbose], do: print_output("データ移行処理を開始...")

    case Migrate.run(args, opts) do
      {:ok, output} ->
        print_output(output)
        exit_with_code(0)

      {:error, reason} ->
        print_output("❌ 移行エラー: #{reason}")
        exit_with_code(1)
    end
  end

  defp process_impl({:cache, args, opts}) do
    if opts[:verbose], do: print_output("キャッシュ操作を開始...")

    case Cache.run(args, opts) do
      {:ok, output} ->
        print_output(output)
        exit_with_code(0)

      {:error, reason} ->
        print_output("❌ キャッシュエラー: #{reason}")
        exit_with_code(1)
    end
  end

  defp process_impl({:infer_student_id, repo_name, opts}) do
    if opts[:verbose], do: print_output("学生ID推論を開始: #{repo_name}")

    case InferStudentId.run([repo_name], opts) do
      {:ok, output} ->
        print_output(output)
        exit_with_code(0)

      {:error, reason} ->
        print_output("❌ 学生ID推論エラー: #{reason}")
        exit_with_code(1)
    end
  end

  defp process_impl({:edit, repo_name, opts}) do
    if opts[:verbose], do: print_output("リポジトリ編集を開始: #{repo_name}")

    case Edit.run([repo_name], opts) do
      {:ok, output} ->
        print_output(output)
        exit_with_code(0)

      {:error, reason} ->
        print_output("❌ 編集エラー: #{reason}")
        exit_with_code(1)
    end
  end

  defp process_impl({:pr_status, filter, opts}) do
    if opts[:verbose], do: print_output("PR状態確認を開始...")

    # フィルターがある場合はオプションに追加
    opts = if filter, do: Keyword.put(opts, :type, filter), else: opts

    case PrStatus.run([], opts) do
      {:ok, output} ->
        print_output(output)
        exit_with_code(0)

      {:error, reason} ->
        print_output("❌ PR状態確認エラー: #{reason}")
        exit_with_code(1)
    end
  end

  defp process_impl({:propagate_workflow, args, opts}) do
    if opts[:verbose], do: print_output("ワークフロー更新の伝播を開始...")

    case PropagateWorkflow.run(args, opts) do
      {:ok, output} ->
        print_output(output)
        exit_with_code(0)

      {:error, reason} ->
        print_output("❌ ワークフロー伝播エラー: #{reason}")
        exit_with_code(1)
    end
  end
end
