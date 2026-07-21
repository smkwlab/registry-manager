defmodule RegistryManager.CLI.Spec do
  @moduledoc """
  CLI のコマンド・オプション定義の単一ソース。

  OptionParser に渡す strict/aliases、コマンドごとの有効オプション検証、
  enum 値の検証、help 文面はすべてこのモジュールから導出される。
  ここに定義がないオプションはパース段階でエラーになる。
  """

  @repo_types [
    "wr",
    "ise",
    "sotsuron",
    "master",
    "thesis",
    "latex",
    "poster",
    "sotsuron-report",
    "other"
  ]
  @output_formats ["table", "csv", "json"]
  @pr_states ["open", "closed", "all"]
  @pr_sort_keys ["repository", "updated", "created"]
  @list_sort_keys ["name", "time"]

  @doc "リポジトリタイプの正準リスト（--type の enum）"
  def repo_types, do: @repo_types

  @doc "出力形式の正準リスト（--format の enum）"
  def output_formats, do: @output_formats

  @doc "PR 状態の正準リスト（--state の enum）"
  def pr_states, do: @pr_states

  @doc "PR ソートキーの正準リスト（pr-status の --sort の enum）"
  def pr_sort_keys, do: @pr_sort_keys

  @doc "list のソートキーの正準リスト（list の --sort の enum）"
  def list_sort_keys, do: @list_sort_keys

  # オプションカタログ: 名前 → 定義。
  # values が nil 以外なら enum としてパース時に検証される。
  @option_catalog %{
    help: %{type: :boolean, alias: :h, values: nil, doc: "このヘルプを表示"},
    verbose: %{type: :boolean, alias: :v, values: nil, doc: "詳細ログを表示"},
    registry_repo: %{
      type: :string,
      alias: nil,
      values: nil,
      doc: "registry_repo を上書き（owner/repo 形式）"
    },
    config: %{type: :string, alias: :c, values: nil, doc: "設定ファイルのパスを上書き"},
    dry_run: %{type: :boolean, alias: :d, values: nil, doc: "実際の変更を行わない"},
    delete_github_repo: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "GitHubリポジトリ削除コマンドを案内"
    },
    force: %{type: :boolean, alias: :f, values: nil, doc: "確認をスキップ／既存設定を上書き"},
    org: %{type: :string, alias: nil, values: nil, doc: "対象の GitHub organization"},
    long: %{type: :boolean, alias: :l, values: nil, doc: "詳細テーブル表示"},
    show_type: %{type: :boolean, alias: nil, values: nil, doc: "リポジトリタイプ列を表示"},
    show_protection: %{type: :boolean, alias: :p, values: nil, doc: "保護状態列を表示"},
    no_names: %{type: :boolean, alias: nil, values: nil, doc: "学生名を非表示"},
    activity: %{type: :boolean, alias: :a, values: nil, doc: "リポジトリの最終活動時刻を表示"},
    owner_activity: %{type: :boolean, alias: :o, values: nil, doc: "オーナーの活動時刻を表示"},
    show_registry_updated: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "registry_updated_at 列を表示"
    },
    show_both_timestamps: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "リポジトリ/レジストリ両方の時刻列を表示"
    },
    no_cache: %{type: :boolean, alias: nil, values: nil, doc: "キャッシュを使用しない"},
    format: %{type: :string, alias: nil, values: @output_formats, doc: "出力形式"},
    type: %{type: :string, alias: :T, values: @repo_types, doc: "リポジトリタイプでフィルタ"},
    # alias: :t が -t を受理させる（OptionParser は aliases 経由でのみ 1 文字形を解釈する）。
    # 名前と alias が同一なのは、長い形 --t を公開しない短縮専用オプションのため
    t: %{type: :boolean, alias: :t, values: nil, doc: "--sort time の短縮"},
    reverse: %{type: :boolean, alias: :r, values: nil, doc: "ソート順を反転"},
    show_student_id: %{type: :boolean, alias: :s, values: nil, doc: "学生IDを表示"},
    add_owner: %{type: :string, alias: nil, values: nil, doc: "オーナーを追加"},
    remove_owner: %{type: :string, alias: nil, values: nil, doc: "オーナーを削除"},
    set_owners: %{type: :string, alias: nil, values: nil, doc: "オーナーを設定（カンマ区切り）"},
    state: %{type: :string, alias: nil, values: @pr_states, doc: "PR 状態でフィルタ"},
    review_requested: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "レビューリクエスト保留中の PR のみ表示"
    },
    sort: %{type: :string, alias: nil, values: @pr_sort_keys, doc: "ソートキー"},
    all: %{type: :boolean, alias: nil, values: nil, doc: "全リポジトリを対象にする"},
    from_template: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "テンプレートから最新ワークフローを適用してから伝播"
    },
    graduated: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "名簿突合で卒業済み学生の登録リポジトリを一括対象にする"
    },
    list: %{type: :boolean, alias: nil, values: nil, doc: "候補一覧を判定理由つきで表示のみ（実行しない）"},
    interactive: %{
      type: :boolean,
      alias: :i,
      values: nil,
      doc: "候補を 1 件ずつ確認しながら archive（y/n/a/q）"
    },
    review_flow: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "review_flow を明示指定（--no-review-flow で false。省略時はタイプ由来の既定値）"
    }
  }

  # 全コマンドで使えるオプション。
  # registry_repo / config / org は ECOSYSTEM.md 規約の
  # 「CLI フラグ > 環境変数 > ローカル config」を実現する上書きフラグ
  @global_option_names [:help, :verbose, :registry_repo, :config, :org]

  @commands [
    %{
      name: "init",
      aliases: [],
      usage: ["init [owner/repo]"],
      summary:
        "レジストリデータリポジトリの bootstrap（private repo 作成・data/registry.json と README の初期投入・config 生成、冪等）",
      options: [:force],
      examples: ["init", "init smkwlab/thesis-student-registry --org smkwlab"]
    },
    %{
      name: "add",
      aliases: [],
      usage: [
        "add <repo_name> [--type <repo_type>]",
        "add <repo_name> <student_id> <repo_type>"
      ],
      summary: "リポジトリ情報を新規登録（1引数: 推論形式・推奨 / 3引数: 明示的形式）",
      options: [
        :dry_run,
        {:type, %{doc: "リポジトリタイプの推論を上書き（1引数形式のみ。名前に規則がない場合に使用）"}},
        :review_flow
      ],
      examples: [
        "add k21rs001-sotsuron",
        "add myorg/k21rs001-wr",
        "add k21rs001-jsai2026 --type other",
        "add k21rs001-fit26 --type latex --review-flow",
        "add k21rs001-sotsuron k21rs001 sotsuron"
      ]
    },
    %{
      name: "update",
      aliases: [],
      usage: ["update <repo_name> <field> <value>"],
      summary: "既存リポジトリ情報を更新",
      options: [:dry_run],
      examples: ["update k21rs001-fit26 review_flow true"]
    },
    %{
      name: "remove",
      aliases: ["rm"],
      usage: ["remove <repo_name>"],
      summary: "リポジトリ情報をレジストリから削除",
      options: [:dry_run, :delete_github_repo],
      examples: ["remove k21rs001-sotsuron", "remove k21rs001-sotsuron --delete-github-repo"]
    },
    %{
      name: "protect",
      aliases: [],
      usage: ["protect <repo_name>"],
      summary: "ブランチ保護設定完了をマーク",
      options: [:dry_run],
      examples: ["protect k21rs001-sotsuron"]
    },
    %{
      name: "list",
      aliases: ["ls"],
      usage: ["list [filter]"],
      summary: "リポジトリ一覧・状況を表示",
      options: [
        :long,
        :show_type,
        :show_protection,
        :no_names,
        :activity,
        :owner_activity,
        :show_registry_updated,
        :show_both_timestamps,
        :no_cache,
        :format,
        :type,
        {:sort, %{values: @list_sort_keys, doc: "ソートキー（デフォルト: name）"}},
        :t,
        :reverse,
        :show_student_id
      ],
      examples: [
        "list",
        "list --long",
        "list --type wr --long",
        "list --sort time -r",
        "list --format csv"
      ]
    },
    %{
      name: "validate",
      aliases: [],
      usage: ["validate [repo_name]"],
      summary: "データの整合性を検証（全件または単一リポジトリ）",
      options: [:format],
      examples: ["validate", "validate k21rs001-sotsuron", "validate --format json"]
    },
    %{
      name: "cache",
      aliases: ["cache-status", "cache-clear", "cache-refresh"],
      usage: ["cache [status|clear|refresh] [repo_name]"],
      summary: "キャッシュ管理（リポジトリ名指定でそのリポジトリのみ対象）",
      options: [:force],
      examples: ["cache status", "cache clear", "cache status k21rs001-sotsuron"]
    },
    %{
      name: "infer-student-id",
      aliases: [],
      usage: ["infer-student-id <repo_name>"],
      summary: "github_username から CSV を元に学生 ID を推論して設定",
      options: [:dry_run],
      examples: ["infer-student-id 91rs044-wr", "infer-student-id demouser-wr --dry-run"]
    },
    %{
      name: "edit",
      aliases: [],
      usage: ["edit <repo_name>"],
      summary: "リポジトリの GitHub オーナーを編集",
      options: [:add_owner, :remove_owner, :set_owners],
      examples: ["edit k21rs001-sotsuron --add-owner mentor-user"]
    },
    %{
      name: "pr-status",
      aliases: [],
      usage: ["pr-status [filter]"],
      summary: "各リポジトリの Pull Request 状態を表示",
      options: [:format, :type, :state, :review_requested, :sort, :reverse, :no_cache],
      examples: ["pr-status", "pr-status --review-requested", "pr-status --sort updated -r"]
    },
    %{
      name: "propagate-workflow",
      aliases: [],
      usage: ["propagate-workflow <repo_name>", "propagate-workflow --all [--type TYPE]"],
      summary: "ワークフロー更新をドラフトブランチ階層に伝播（main → 0th-draft → … の順でマージ）",
      options: [:all, :type, :from_template, :dry_run],
      examples: [
        "propagate-workflow k92rs001-sotsuron",
        "propagate-workflow --all --type thesis --dry-run"
      ]
    },
    %{
      name: "archive",
      aliases: [],
      usage: [
        "archive <repo_name>",
        "archive --graduated [--list | --dry-run | -i]"
      ],
      summary:
        "卒業済みリポジトリを archive（open PR クローズ → archive → archived_at 記録）。--graduated で名簿突合の一括、--list で候補一覧のみ、--dry-run で副作用なしのシミュレーション、-i で 1 件ずつ確認しながら実行",
      options: [:graduated, :list, :dry_run, :interactive],
      examples: [
        "archive k21rs001-sotsuron",
        "archive --graduated --list",
        "archive --graduated --dry-run",
        "archive --graduated",
        "archive --graduated -i"
      ]
    }
  ]

  @doc "コマンド定義の一覧"
  def commands, do: @commands

  @doc "コマンド名（エイリアス除く）の一覧"
  def command_names, do: Enum.map(@commands, & &1.name)

  @doc "名前またはエイリアスからコマンド定義を引く"
  def find_command(name) do
    Enum.find(@commands, fn command ->
      command.name == name or name in command.aliases
    end)
  end

  @doc """
  コマンドが使えるオプション定義（グローバル含む）。

  options の要素は名前(atom)か {名前, 上書きマップ} で、
  上書きマップでコマンド固有の values / doc を差し替えられる。
  """
  def options_for(%{options: entries}) do
    Enum.map(@global_option_names ++ entries, &resolve_option/1)
  end

  defp resolve_option(name) when is_atom(name) do
    @option_catalog
    |> Map.fetch!(name)
    |> Map.put(:name, name)
  end

  defp resolve_option({name, override}) do
    @option_catalog
    |> Map.fetch!(name)
    |> Map.merge(override)
    |> Map.put(:name, name)
  end

  @doc "OptionParser の strict リスト（全オプションの和集合）"
  def strict_switches do
    Enum.map(@option_catalog, fn {name, %{type: type}} -> {name, type} end)
  end

  @doc "OptionParser の aliases リスト"
  def aliases do
    for {name, %{alias: short}} <- @option_catalog, short != nil, do: {short, name}
  end

  @doc "コマンドが受け付けるオプション名の MapSet（未知のコマンドは nil）"
  def allowed_for(name) do
    case find_command(name) do
      nil -> nil
      command -> MapSet.new(options_for(command), & &1.name)
    end
  end

  @doc """
  パース済みオプションをコマンド定義に対して検証する。

  コマンドに属さないオプションと enum 違反（コマンド固有の values を含む）を
  エラーにする。コマンド名が nil または未知の場合は :ok（dispatch 側が
  :help に落とす）。
  """
  def validate_opts(command_name, opts) do
    case find_command(command_name) do
      nil -> :ok
      command -> check_opts(command.name, opts, Map.new(options_for(command), &{&1.name, &1}))
    end
  end

  defp check_opts(command_name, opts, defs) do
    case Enum.flat_map(opts, &opt_violation(&1, command_name, defs)) do
      [] -> :ok
      messages -> {:error, Enum.join(messages, "\n")}
    end
  end

  defp opt_violation({name, value}, command_name, defs) do
    case defs[name] do
      nil ->
        ["--#{render_name(name)} は #{command_name} コマンドでは使えません"]

      %{values: values} when is_list(values) ->
        if value in values do
          []
        else
          ["--#{render_name(name)} の値が不正です: #{value}（有効な値: #{Enum.join(values, ", ")}）"]
        end

      _ ->
        []
    end
  end

  @doc "グローバル help を spec から生成する"
  def render_help do
    command_sections = Enum.map_join(@commands, "\n", &render_command_section/1)

    """
    registry-manager - 学生リポジトリレジストリ管理ツール

    使用方法:
      registry-manager <command> [options]
      registry-manager <command> --help

    コマンド:
    #{command_sections}
    グローバルオプション:
    #{render_options(global_options())}
    例:
    #{render_examples(@commands)}
    """
  end

  @doc "コマンド単体の help を spec から生成する（未知のコマンドは nil）"
  def render_command_help(name) do
    case find_command(name) do
      nil ->
        nil

      command ->
        """
        registry-manager #{command.name} - #{command.summary}

        使用方法:
        #{Enum.map_join(command.usage, "\n", &"  registry-manager #{&1}")}

        オプション:
        #{render_options(options_for(command))}
        例:
        #{Enum.map_join(command.examples, "\n", &"  registry-manager #{&1}")}
        """
    end
  end

  defp render_command_section(command) do
    usage_lines = Enum.map_join(command.usage, "\n", &"  #{&1}")

    option_names =
      Enum.map_join(command.options, " ", fn entry ->
        entry |> resolve_option() |> render_option_name()
      end)

    option_line =
      if command.options == [] do
        ""
      else
        "      オプション: #{option_names}\n"
      end

    "#{usage_lines}\n      #{command.summary}\n#{option_line}"
  end

  defp render_options(options) do
    Enum.map_join(options, "\n", &render_option_line/1)
  end

  defp render_option_line(option) do
    value = if option.type == :string, do: " #{render_values(option)}", else: ""

    if single_char_name?(option.name) do
      "  -#{option.name}#{value}  #{option.doc}"
    else
      short = if option.alias, do: "-#{option.alias}, ", else: "    "
      "  #{short}--#{render_name(option.name)}#{value}  #{option.doc}"
    end
  end

  # 1 文字名のオプション（:t など）は短縮形のみを持つ
  defp render_option_name(option) do
    if single_char_name?(option.name) do
      "-#{option.name}"
    else
      "--#{render_name(option.name)}"
    end
  end

  defp single_char_name?(name), do: byte_size(Atom.to_string(name)) == 1

  defp render_values(%{values: values}) when is_list(values), do: Enum.join(values, "|")
  defp render_values(_), do: "VALUE"

  defp render_examples(commands) do
    commands
    |> Enum.flat_map(& &1.examples)
    |> Enum.map_join("\n", &"  registry-manager #{&1}")
  end

  defp global_options do
    Enum.map(@global_option_names, &resolve_option/1)
  end

  defp render_name(name), do: String.replace(Atom.to_string(name), "_", "-")
end
