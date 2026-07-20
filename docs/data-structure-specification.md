# Registry Manager データ構造仕様書

**バージョン**: 1.0  
**作成日**: 2025-07-09  
**対象**: registry-manager データ構造  
**Issue**: #65 - registry-manager の仕様整理と再開発計画

## 概要

registry-manager で管理される学生リポジトリデータの構造仕様を定義します。

## 1. データ構造

### 1.1 リポジトリエントリの例

**ファイル**: `data/registry.json`

```json
{
  "repository_name": {
    "student_id": "k91rs044",
    "repository_type": "wr",
    "created_at": "2025-07-08T06:51:39.835808Z",
    "registry_updated_at": "2025-07-08T15:30:00.000000Z",
    "review_flow": false,
    "github_username": ["mockuser3"],
    "protection_status": "protected"
  }
}
```

## 2. 標準データ構造仕様

### 2.1 リポジトリエントリ構造

**基本構造**
```json
{
  "repository_name": {
    "student_id": "string",
    "repository_type": "string",
    "created_at": "string (ISO8601)",
    "registry_updated_at": "string (ISO8601)",
    "review_flow": "boolean",
    "github_username": ["string"],
    "protection_status": "string"
  }
}
```

### 2.2 フィールド仕様

#### 2.2.1 必須フィールド

| フィールド名 | 型 | 説明 | 制約 | 取得方法 |
|-------------|---|------|------|---------|
| `student_id` | string | 学生ID | 形式: `k##[a-z]{2}###` | 推論または手動指定 |
| `repository_type` | string | リポジトリタイプ | 値: `wr`, `ise`, `ise-report`, `sotsuron`, `master`, `latex`, `poster`, `other` | 推論または手動指定 |
| `created_at` | string | リポジトリ作成日時 | ISO8601形式（小数秒可）。少なくとも `created_at` か `registry_updated_at` の一方が必要 | GitHub API |
| `registry_updated_at` | string | レジストリ最終更新日時 | ISO8601形式（小数秒可）。少なくとも `created_at` か `registry_updated_at` の一方が必要 | registry-manager / 登録自動化 |
| `review_flow` | boolean | draft PR サイクルで運用するリポジトリか | タイプとは独立した属性。登録時の既定値: sotsuron / master / ise（`ise-report` 表記も同様）/ poster → true、wr / other → false、latex → false（作成時オプトイン）。読み手はタイプからのフォールバック推論をしない | 登録時に決定（`--review-flow` で上書き可） |
| `github_username` | string[] | GitHubユーザー名（複数オーナー対応） | GitHub ID の配列。レガシーの string 形式も読み込み時に配列へ正規化される（`Compatibility.normalize_github_username/1`） | GitHub API または推論 |

#### 2.2.2 任意フィールド

| フィールド名 | 型 | 説明 | 制約 | デフォルト値 |
|-------------|---|------|------|------------|
| `protection_status` | string | ブランチ保護状態 | 値: `protected`, `unprotected`, `unknown` | `unknown` |
| `archived_at` | string | archive 実行日時（`archive` コマンドが記録） | ISO8601 形式。存在するエントリは歴史データとして validate の検証対象外（件数のみ報告） | なし（active） |

#### 2.2.3 廃止フィールド

データからは除去済み。validate が再流入を警告する。

| フィールド名 | 廃止理由 | 代替手段 |
|-------------|---------|---------|
| `status` | 設計上不要 | リポジトリタイプで判断 |
| `stage` | 設計上不要 | リポジトリタイプで判断 |
| `updated_at` | 命名不統一 | `registry_updated_at` を使用 |

### 2.3 リポジトリタイプ仕様

#### 2.3.1 定義されたタイプ

| タイプ | 説明 | 命名規則 |
|--------|------|---------|
| `wr` | 週報 | `*-wr` |
| `ise` / `ise-report` | ISE レポート | `*-ise-report*` |
| `sotsuron` | 卒業論文 | `*-sotsuron` |
| `master` | 修士論文 | `*-master` |
| `latex` | latex-template 派生（研究会・学会原稿等） | `*-fit*`, `*-hinokuni*` など任意 |
| `poster` | 学会ポスター（poster-template 派生） | 任意 |
| `other` | 上記以外 | 任意 |

**補足**: `thesis` は repository_type の語彙では**ない**（repo 名 suffix・
文書種別 DOC_TYPE・「論文まとめ」フィルタ名としてのみ使用する。
smkwlab/student-repo-management#471 の設計決定を参照）。
命名規則は推論の目安であり、明示指定で任意タイプを登録できる。

#### 2.3.2 タイプ推論ルール

```
Repository Name Pattern → Repository Type
*-wr                   → wr
*-ise-report*          → ise
*-sotsuron             → sotsuron
*-master / *-thesis    → master
その他                 → other
```

**注**: 推論・自動化は `ise` を出力し、実データにも `ise` で格納される（validation は `ise-report` も受理する）。
`latex` / `poster` は名前から推論されないため、`--type` での明示指定が必要（指定がなければ `other` になる）。

### 2.4 学生ID形式仕様

#### 2.4.1 標準形式

**パターン**: `k##[a-z]{2}###`

**例**:
- `k21rs001`
- `k92jk015`
- `k93rs099`

#### 2.4.2 正規化ルール

**入力形式** → **正規化後**
- `80JK059` → `k80jk059`
- `K21RS001` → `k21rs001`
- `k21rs001` → `k21rs001` (変更なし)

### 2.5 時刻形式仕様

#### 2.5.1 標準形式

**ISO8601 UTC形式**: `YYYY-MM-DDTHH:MM:SS.ffffffZ`（小数部はマイクロ秒 6 桁が標準。検証は桁数可変を許容する）

**例**: `2025-07-08T06:51:39.835808Z`

#### 2.5.2 表示形式

**JST形式**: `YYYY-MM-DD HH:MM:SS`

**例**: `2025-07-08 15:51:39`

#### 2.5.3 レガシー形式（非推奨）

**カスタム形式**: `YYYY-MM-DD HH:MM:SS UTC`

**例**: `2025-07-06 16:20:06 UTC`

## 3. 外部データ連携仕様

### 3.1 学生名データ（CSV）

#### 3.1.1 ファイル構造

**パス**: config の `csv_path` または環境変数 `REGISTRY_MANAGER_CSV_PATH` で
指定する任意のローカルファイル。任意設定で、未設定なら氏名解決なしで動作する。
ファイル名は自由で、`smkwlab.csv` は例示に過ぎない。名簿 CSV はローカル限定で
管理し、リポジトリにもレジストリにもコミットしない。
（詳細は[プライバシー方針](../README.md#プライバシーに関する注意)を参照）

**形式**:
```csv
column1,column2,student_id,name,column5,...
value1,value2,80JK059,田中太郎,value5,...
```

#### 3.1.2 データマッピング

**CSVの学生ID** → **レジストリの学生ID**
- `80JK059` → `k80jk059`
- `21RS001` → `k21rs001`

### 3.2 GitHub APIデータ

#### 3.2.1 リポジトリ情報

**API**: `GET /repos/{owner}/{repo}`

**取得データ**:
- `owner.login`: GitHub ユーザー名
- `created_at`: リポジトリ作成日時
- `updated_at`: 最終更新日時

#### 3.2.2 コミット情報

**API**: `GET /repos/{owner}/{repo}/commits`

**取得データ**:
- `commit.author.date`: コミット日時
- `author.login`: コミット作成者

## 4. データ整合性仕様

### 4.1 一意性制約

#### 4.1.1 プライマリキー

**リポジトリ名**: 全システムで一意

**制約**:
- 重複登録の禁止
- 削除後の再登録は許可

#### 4.1.2 学生ID制約

**複数リポジトリ**: 1人の学生が複数のリポジトリを持つことは許可

**例**:
```json
{
  "k21rs001-wr": {
    "student_id": "k21rs001",
    "repository_type": "wr"
  },
  "k21rs001-sotsuron": {
    "student_id": "k21rs001",
    "repository_type": "sotsuron"
  }
}
```

### 4.2 参照整合性

#### 4.2.1 GitHub ユーザー名

**制約**: 実在するGitHubユーザーである必要

**検証方法**: GitHub API による実在確認

#### 4.2.2 学生ID

**制約**: `csv_path` 設定時のみ、CSV に存在する学生 ID との照合を行う任意チェック
（必須ではない）

**検証方法**: CSV データとのマッピング確認（未設定なら照合はスキップし氏名解決なしで動作）

**注意**: `csv_path` は任意設定のため、CSV 未設定の環境ではこの照合は
スキップされる（形式検証 4.3.1 のみ実施）。CSV 照合はエラーではなく
氏名解決の可否にのみ影響する。

### 4.3 データ検証ルール

#### 4.3.1 フォーマット検証

```elixir
# 学生ID形式チェック（現行の学籍番号体系: k + 入学年2桁 + 課程2文字 + 連番3桁。
# 体系変更時は本仕様の改定とあわせて更新する）
student_id_pattern = ~r/^k\d{2}[a-z]{2}\d{3}$/

# リポジトリタイプチェック
valid_types = ["wr", "ise", "ise-report", "sotsuron", "master", "latex", "poster", "other"]

# 時刻形式チェック（ISO8601）
# 小数部は \d+ で桁数可変を許容（標準は 6 桁だが、過去データに桁数の
# 揺れがあるため意図的に緩い検証としている）
iso8601_pattern = ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z$/
```

#### 4.3.2 論理検証

**リポジトリタイプ整合性**:
- リポジトリ名とタイプの整合性確認
- 例: `k21rs001-wr` → `repository_type` は `wr` である必要

**時刻整合性**:
- 通常は `created_at` <= `registry_updated_at`（リポジトリ作成後にレジストリが更新される）
- 未来の時刻は不可

## 5. 今後の拡張計画

### 5.1 短期計画

1. **バリデーション強化**
   - より厳密なデータ検証
   - 自動修復機能

### 5.2 中期計画

1. **メタデータ追加**
   - 作成者情報
   - 更新履歴
   - タグ機能

2. **外部システム連携**
   - 成績管理システム連携
   - 出席管理システム連携

### 5.3 長期計画

1. **データベース化**
   - SQLiteへの移行
   - 複雑なクエリ対応

2. **分散管理**
   - 複数インスタンス対応
   - 同期機能

## 6. 制約事項

### 6.1 技術的制約

- JSON形式での管理（現在）
- ファイルサイズ制限（GitHub API制限）
- 文字エンコーディング: UTF-8

### 6.2 運用制約

- 同時更新の制限
- バックアップの手動管理
- 大量データ処理の制限

## 7. 用語集

| 用語 | 説明 |
|------|------|
| レジストリ | 学生リポジトリ情報を管理するJSONファイル |
| エントリ | レジストリ内の1つのリポジトリ情報 |
| 正規化 | データ形式の統一化 |
| ISO8601 | 国際標準の日時形式 |
