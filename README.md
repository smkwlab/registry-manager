# Registry Manager

多数の学生リポジトリ（週報・レポート・卒業論文など）を一括管理するための
リポジトリレジストリ管理ツール（Elixir escript）。

GitHub 上のレジストリデータリポジトリに置いた `data/registry.json`
（旧名 `data/repositories.json` も移行期間中は自動で読み書き）を GitHub API
経由で安全に読み書きし、リポジトリの登録・更新・ブランチ保護状況の管理・
一覧表示・ワークフロー伝播などを行います。

## 特徴

- **GitHub API 統合**: データリポジトリへの読み書きはすべて GitHub API 経由
- **原子性**: GitHub のバージョン管理（SHA 検証）による安全な更新
- **並行安全性**: API レベルでの競合回避
- **監査性**: すべての変更が Git 履歴に記録
- **プライバシー分離**: 学生の個人情報（氏名 CSV・レジストリデータ）は
  ツール本体から分離され、private なデータリポジトリ／ローカルファイルに保持

## セットアップ

### 一括セットアップ（推奨）: `init`

```bash
# private データリポジトリの作成 + data/registry.json / README の初期投入 +
# ~/.config/registry-manager/config.json の生成までを冪等に行う
registry-manager init your-org/your-student-registry

# 既存の config を上書きする場合
registry-manager init your-org/your-student-registry --force
```

既存のリポジトリ・ファイル・config は上書きせずスキップして報告します。
読み取り側（監視ツール）のセットアップは
[thesis-monitor](https://github.com/smkwlab/thesis-monitor) の `init` を使用してください。

以下は手動でセットアップする場合の手順です。

### 1. データリポジトリの用意

学生リポジトリの情報を保持する **private リポジトリ** を用意し、
`data/registry.json` を置きます（空の `{}` から開始可能）。

```json
{
  "k21rs001-sotsuron": {
    "student_id": "k21rs001",
    "repository_type": "sotsuron",
    "github_username": ["k21rs001"],
    "created_at": "2025-07-02 04:04:53 UTC",
    "updated_at": "2025-07-02 04:04:53 UTC",
    "protection_status": "protected"
  }
}
```

詳細は [データ構造仕様書](docs/data-structure-specification.md) を参照。

### 2. 設定ファイルの作成

`~/.config/registry-manager/config.json`:

```json
{
  "github_org": "your-org",
  "registry_repo": "your-org/your-student-registry",
  "csv_path": "/path/to/students.csv",
  "test_student_ids": ["k99rs998", "k99rs999"]
}
```

| キー | 必須 | 説明 |
|---|---|---|
| `github_org` | 推奨 | 学生リポジトリが属する GitHub Organization |
| `registry_repo` | GitHub データ操作時に必須 | `owner/repo` 形式のレジストリデータリポジトリ（旧キー `data_repo` も当面は警告付きで受理） |
| `csv_path` | 任意 | 学生名簿 CSV（氏名解決用）。未設定なら氏名解決なしで動作 |
| `test_student_ids` | 任意 | 本番データ保護チェックでテストデータ扱いする学生 ID |

環境変数でも設定できます:
`REGISTRY_MANAGER_GITHUB_ORG` / `REGISTRY_MANAGER_REGISTRY_REPO` /
`REGISTRY_MANAGER_CSV_PATH` / `REGISTRY_MANAGER_TEST_STUDENT_IDS`（カンマ区切り）

優先順位は **設定ファイル > 環境変数 > デフォルト値** です（同じキーを両方で
指定した場合は設定ファイルの値が使われます）。一般的な慣習
（環境変数 > 設定ファイル、いわゆる 12-factor 流）とは逆ですが、
管理者が明示的に書いた設定ファイルを、シェル環境に残った一時的な
環境変数より優先する意図的な設計です。

### 3. ビルド

```bash
mix deps.get
mix escript.build
```

## 前提条件

- Elixir >= 1.14
- GitHub CLI（`gh auth login` 済み）
- データリポジトリへの書き込み権限

## 使用方法

```bash
# リポジトリ情報追加（リポジトリ名から学生ID・種別を推論）
./registry-manager add k21rs001-sotsuron

# 明示的形式
./registry-manager add k21rs001-sotsuron k21rs001 sotsuron

# ブランチ保護設定完了マーク
./registry-manager protect k21rs001-sotsuron

# 一覧表示（フィルタ・出力形式）
./registry-manager list --long
./registry-manager list --type wr --format csv

# データ検証
./registry-manager validate

# ワークフロー更新のドラフトブランチ伝播
./registry-manager propagate-workflow k21rs001-sotsuron --dry-run

# ヘルプ
./registry-manager --help
```

## 開発

```bash
mix test           # テスト実行（TDD、カバレッジ 85% 以上を維持）
mix format         # フォーマット
mix credo --strict # 静的解析
mix dialyzer       # 型チェック
```

## アーキテクチャ

- `RegistryManager.CLI`: コマンドライン処理
- `RegistryManager.Config`: 設定管理（設定ファイル > 環境変数 > デフォルト）
- `RegistryManager.Repository`: リポジトリ情報管理ロジック
- `RegistryManager.GitHubAPI`: GitHub API オーケストレーション
  - `Client`: 外部コマンド（gh）実行
  - `Parser`: レスポンス変換・検証（純粋関数）

## プライバシーに関する注意

このツール自体は学生の個人情報を含みませんが、運用時に扱うデータには
個人情報が含まれます。機密レベルに応じて二段階で分離します:

- **`data/registry.json`（学生 ID・GitHub アカウント）**: レジストリデータ
  リポジトリ（thesis-student-registry）で管理。必ず **private** にする。
- **名簿 CSV（氏名を含む）**: 一段機密が高いため、**ローカル限定**で管理し、
  ツール本体リポジトリにもレジストリにも一切コミットしない。ツールは
  `csv_path` / `REGISTRY_MANAGER_CSV_PATH` で指定した任意のローカルパスから
  読むのみ（任意設定）。

## ライセンス

[MIT License](LICENSE)
