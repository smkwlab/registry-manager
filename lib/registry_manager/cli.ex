defmodule RegistryManager.CLI do
  @moduledoc """
  CLI interface for registry manager
  """

  alias RegistryManager.CLI.Spec
  alias RegistryManager.Commands.Archive
  alias RegistryManager.Commands.Cache
  alias RegistryManager.Commands.Edit
  alias RegistryManager.Commands.InferStudentId
  alias RegistryManager.Commands.Init
  alias RegistryManager.Commands.List
  alias RegistryManager.Commands.Migrate
  alias RegistryManager.Commands.PropagateWorkflow
  alias RegistryManager.Commands.PrStatus
  alias RegistryManager.Commands.Validate
  alias RegistryManager.Config
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
    {opts, argv, invalid} =
      OptionParser.parse(args, strict: Spec.strict_switches(), aliases: Spec.aliases())

    cond do
      invalid != [] ->
        {:error, "不明なオプション: #{Enum.map_join(invalid, ", ", fn {name, _} -> name end)}"}

      opts[:help] ->
        parse_help_target(argv)

      true ->
        parse_validated_command(argv, opts)
    end
  end

  # `<command> --help` はコマンド単体の help に落とす
  defp parse_help_target([first | _]) do
    case Spec.find_command(first) do
      nil -> :help
      command -> {:help_command, command.name}
    end
  end

  defp parse_help_target(_), do: :help

  # コマンドに属さないオプションと enum 違反をパース段階でエラーにする
  defp parse_validated_command(argv, opts) do
    with :ok <- Spec.validate_opts(first_arg(argv), opts),
         :ok <- apply_config_overrides(opts) do
      parse_command(argv, opts)
    else
      {:error, _} = error -> error
    end
  end

  # CLI フラグによる設定上書き（ECOSYSTEM.md 規約: CLI > env > config > default）。
  # Config.load_config() は約 20 箇所からアドホックに呼ばれるため、struct を
  # 引き回さず Application env を最終マージレイヤとして渡す
  defp apply_config_overrides(opts) do
    with :ok <- validate_registry_repo_opt(opts[:registry_repo]) do
      put_config_overrides(opts)
      :ok
    end
  end

  defp validate_registry_repo_opt(nil), do: :ok

  defp validate_registry_repo_opt(value) do
    if Config.valid_registry_repo?(value) do
      :ok
    else
      {:error, "--registry-repo は owner/repo 形式で指定してください: #{value}"}
    end
  end

  defp put_config_overrides(opts) do
    overrides =
      [registry_repo: opts[:registry_repo], github_org: opts[:org]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    # フラグ未指定時は削除し、前回実行の値が残留しないようにする
    if map_size(overrides) > 0 do
      Application.put_env(:registry_manager, :cli_overrides, overrides)
    else
      Application.delete_env(:registry_manager, :cli_overrides)
    end

    if opts[:config] do
      Application.put_env(:registry_manager, :config_path, opts[:config])
    else
      Application.delete_env(:registry_manager, :config_path)
    end
  end

  defp first_arg([first | _]), do: first
  defp first_arg(_), do: nil

  @doc false
  def known_commands do
    Map.keys(command_parser_map()) -- ["cache-alias"]
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
  defp normalize_command(["cache-status" | args]), do: {"cache-alias", ["status" | args]}
  defp normalize_command(["cache-clear" | args]), do: {"cache-alias", ["clear" | args]}
  defp normalize_command(["cache-refresh" | args]), do: {"cache-alias", ["refresh" | args]}
  defp normalize_command([command | args]), do: {command, args}
  defp normalize_command(_), do: nil

  # コマンド → パーサー関数のマッピング
  defp command_parser_map do
    %{
      "add" => &parse_add_command/2,
      "init" => &parse_init_command/2,
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
      "propagate-workflow" => &parse_propagate_workflow_command/2,
      "archive" => &parse_archive_command/2
    }
  end

  # cache-*エイリアス専用パーサー
  defp parse_cache_alias(args, opts) do
    parse_cache_command(args, opts)
  end

  defp parse_add_command([repo_name], opts) do
    {:add_auto, repo_name, opts}
  end

  defp parse_add_command([repo_name, student_id, repo_type], opts) do
    if opts[:type] do
      {:error, "--type は 1 引数形式でのみ使えます（3 引数形式では第 3 引数でタイプを指定してください）"}
    else
      {:add_explicit, {repo_name, student_id, repo_type}, opts}
    end
  end

  defp parse_add_command([_repo_name, _student_id, _repo_type, _status | _stage], _opts) do
    {:error, "旧形式のadd コマンドは廃止されました。新形式を使用してください: add <repo_name> <student_id> <repo_type>"}
  end

  defp parse_add_command(_, _opts), do: :help

  defp parse_init_command(args, opts) when length(args) <= 1, do: {:init, args, opts}
  defp parse_init_command(_, _opts), do: :help

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

  defp parse_list_command([], opts), do: {:list, nil, normalize_list_sort(opts)}
  defp parse_list_command([filter], opts), do: {:list, filter, normalize_list_sort(opts)}
  defp parse_list_command(_, _opts), do: :help

  # -t は --sort time の短縮（明示的な --sort が優先）。
  # OptionParser は同一スイッチの重複で末尾を採用するが、:sort と :t は別スイッチ
  # なので順序に依らず opts に両方残り、put_new が明示的な :sort を保護する
  defp normalize_list_sort(opts) do
    if opts[:t] do
      opts |> Keyword.delete(:t) |> Keyword.put_new(:sort, "time")
    else
      opts
    end
  end

  defp parse_validate_command([], opts), do: {:validate, [], opts}
  defp parse_validate_command([repo_name], opts), do: {:validate, [repo_name], opts}
  defp parse_validate_command(_, _opts), do: :help

  defp parse_migrate_command([], opts), do: {:migrate, [], opts}
  defp parse_migrate_command([subcommand], opts), do: {:migrate, [subcommand], opts}
  defp parse_migrate_command(_, _opts), do: :help

  defp parse_cache_command([], opts), do: {:cache, [], opts}
  defp parse_cache_command([subcommand], opts), do: {:cache, [subcommand], opts}

  defp parse_cache_command([subcommand, repo_name], opts),
    do: {:cache, [subcommand, repo_name], opts}

  defp parse_cache_command(_, _opts), do: :help

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

  defp parse_propagate_workflow_command([repo_name], opts),
    do: {:propagate_workflow, [repo_name], opts}

  defp parse_propagate_workflow_command(_, _opts), do: :help

  defp parse_archive_command([repo_name], opts), do: {:archive, [repo_name], opts}

  defp parse_archive_command([], opts) do
    if opts[:graduated] do
      {:archive, [], opts}
    else
      :help
    end
  end

  defp parse_archive_command(_, _opts), do: :help

  @spec process_impl(any()) :: no_return()
  defp process_impl(:help) do
    print_output(Spec.render_help())
    exit_with_code(0)
  end

  defp process_impl({:help_command, name}) do
    print_output(Spec.render_command_help(name))
    exit_with_code(0)
  end

  defp process_impl({:error, reason}) do
    print_output("❌ エラー: #{reason}")
    exit_with_code(1)
  end

  defp process_impl({:init, args, opts}) do
    case Init.run(args, opts) do
      {:ok, _repo} -> exit_with_code(0)
      {:error, _reason} -> exit_with_code(1)
    end
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

  defp process_impl({:validate, args, opts}) do
    if opts[:verbose], do: print_output("データ整合性検証を開始...")

    case Validate.run(args, opts) do
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

  defp process_impl({:archive, args, opts}) do
    if opts[:verbose], do: print_output("archive 処理を開始...")

    case Archive.run(args, opts) do
      {:ok, output} ->
        print_output(output)
        exit_with_code(0)

      {:error, reason} ->
        print_output("❌ archive エラー: #{reason}")
        exit_with_code(1)
    end
  end
end
