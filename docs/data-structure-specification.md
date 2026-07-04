# Registry Manager データ構造仕様書

**バージョン**: 1.0  
**作成日**: 2025-07-09  
**対象**: registry-manager データ構造  
**Issue**: #65 - registry-manager の仕様整理と再開発計画

## 概要

registry-manager で管理される学生リポジトリデータの構造仕様を定義します。現在の新旧混在状態を整理し、統一されたデータ構造への移行計画を示します。

## 1. データ構造の現状

### 1.1 新データ構造（推奨）

**ファイル**: `data/repositories.json`

```json
{
  "repository_name": {
    "student_id": "k91rs044",
    "repository_type": "wr",
    "repository_created_at": "2025-07-08T06:51:39.835808Z",
    "registry_created_at": "2025-07-08T15:00:00.000000Z",
    "registry_updated_at": "2025-07-08T15:30:00.000000Z",
    "github_username": "mockuser3",
    "protection_status": "protected"
  }
}
```

### 1.2 旧データ構造（非推奨）

```json
{
  "repository_name": {
    "student_id": "k88rs509",
    "repository_type": "ise",
    "status": "active",
    "stage": "ise",
    "updated_at": "2025-07-06 16:20:06 UTC",
    "github_username": "k88rs509",
    "protection_status": "protected"
  }
}
```

### 1.3 移行が必要な問題点

1. **時刻フィールドの不統一**
   - 新: `registry_updated_at` (ISO8601形式)
   - 旧: `updated_at` (カスタム形式)

2. **不要フィールドの存在**
   - `status`: 削除対象（設計上不要）
   - `stage`: 削除対象（設計上不要）

3. **時刻フィールドの不足**
   - 旧エントリに `repository_created_at` と `registry_created_at` が不足
   - 3つの時刻フィールドへの統一が必要

4. **時刻形式の不統一**
   - 新: ISO8601形式（`2025-07-08T06:51:39.835808Z`）
   - 旧: カスタム形式（`2025-07-06 16:20:06 UTC`）

5. **データ検証の不完全性**
   - 旧エントリの一部で必須フィールドが欠損
   - ブランチ保護状態が未設定

## 2. 標準データ構造仕様

### 2.1 リポジトリエントリ構造

**基本構造**
```json
{
  "repository_name": {
    "student_id": "string",
    "repository_type": "string",
    "repository_created_at": "string (ISO8601)",
    "registry_created_at": "string (ISO8601)",
    "registry_updated_at": "string (ISO8601)",
    "github_username": "string",
    "protection_status": "string"
  }
}
```

### 2.2 フィールド仕様

#### 2.2.1 必須フィールド

| フィールド名 | 型 | 説明 | 制約 | 取得方法 |
|-------------|---|------|------|---------|
| `student_id` | string | 学生ID | 形式: `k##[a-z]{2}###` | 推論または手動指定 |
| `repository_type` | string | リポジトリタイプ | 値: `wr`, `ise`, `sotsuron`, `thesis` | 推論または手動指定 |
| `repository_created_at` | string | リポジトリ作成日時 | ISO8601形式 | GitHub API |
| `registry_created_at` | string | レジストリ初回登録日時 | ISO8601形式 | registry-manager |
| `registry_updated_at` | string | レジストリ最終更新日時 | ISO8601形式 | registry-manager |
| `github_username` | string | GitHubユーザー名 | GitHub ID | GitHub API または推論 |

#### 2.2.2 任意フィールド

| フィールド名 | 型 | 説明 | 制約 | デフォルト値 |
|-------------|---|------|------|------------|
| `protection_status` | string | ブランチ保護状態 | 値: `protected`, `unprotected`, `unknown` | `unknown` |

#### 2.2.3 削除予定フィールド

| フィールド名 | 削除理由 | 代替手段 |
|-------------|---------|---------|
| `status` | 設計上不要 | リポジトリタイプで判断 |
| `stage` | 設計上不要 | リポジトリタイプで判断 |
| `updated_at` | 命名不統一 | `registry_updated_at` を使用 |
| `created_at` | 曖昧な命名 | `repository_created_at` と `registry_created_at` に分離 |

### 2.3 リポジトリタイプ仕様

#### 2.3.1 定義されたタイプ

| タイプ | 説明 | 命名規則 |
|--------|------|---------|
| `wr` | 週報 | `*-wr` |
| `ise` | ISE レポート | `*-ise-report*` |
| `sotsuron` | 卒業論文 | `*-sotsuron` |
| `thesis` | 論文（その他） | `*-memo*` |

#### 2.3.2 タイプ推論ルール

```
Repository Name Pattern → Repository Type
*-wr                   → wr
*-ise-report*          → ise
*-sotsuron             → sotsuron
*-memo*                → thesis
```

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

**ISO8601 UTC形式**: `YYYY-MM-DDTHH:MM:SS.fffffZ`

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

**ファイル名**: `smkwlab.csv`

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

**制約**: CSVファイルに存在する学生IDである必要

**検証方法**: CSV データとのマッピング確認

### 4.3 データ検証ルール

#### 4.3.1 フォーマット検証

```elixir
# 学生ID形式チェック
student_id_pattern = ~r/^k\d{2}[a-z]{2}\d{3}$/

# リポジトリタイプチェック
valid_types = ["wr", "ise", "sotsuron", "thesis"]

# 時刻形式チェック（ISO8601）
iso8601_pattern = ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z$/
```

#### 4.3.2 論理検証

**リポジトリタイプ整合性**:
- リポジトリ名とタイプの整合性確認
- 例: `k21rs001-wr` → `repository_type` は `wr` である必要

**時刻整合性**:
- `repository_created_at` <= `registry_created_at` <= `registry_updated_at`
- 未来の時刻は不可

## 5. データ移行仕様

### 5.1 移行対象データ

#### 5.1.1 フィールド変換

| 旧フィールド | 新フィールド | 変換処理 |
|-------------|-------------|---------|
| `updated_at` | `registry_updated_at` | 時刻形式変換 |
| `created_at` (曖昧) | `registry_created_at` | `updated_at` と同じ値またはGitHub APIから取得 |
| （なし） | `repository_created_at` | GitHub APIから取得 |

#### 5.1.2 フィールド削除

| 削除フィールド | 削除理由 |
|---------------|---------|
| `status` | 設計上不要 |
| `stage` | 設計上不要 |

### 5.2 移行手順

#### 5.2.1 バックアップ

1. 現在の `repositories.json` をバックアップ
2. 移行ログファイルの作成
3. 移行前データの検証

#### 5.2.2 データ変換

1. 各エントリの形式確認
2. 時刻形式の変換
3. 不要フィールドの削除
4. 欠損フィールドの補完

#### 5.2.3 検証

1. 変換後データの整合性確認
2. すべてのエントリの形式確認
3. 外部データとの整合性確認

### 5.3 移行ツール仕様

#### 5.3.1 独立移行ツール仕様

**※重要**: データ移行は registry-manager 本体ではなく、独立ツール `registry-migrator` で実行

```bash
# データ移行の実行
elixir tools/registry_migrator.ex --execute

# 移行状況の確認
elixir tools/registry_migrator.ex --status

# 移行のロールバック
elixir tools/registry_migrator.ex --rollback
```

#### 5.3.2 移行ログ

**ログ形式**:
```
[2025-07-09T10:00:00.000Z] MIGRATE START
[2025-07-09T10:00:01.000Z] BACKUP created: backup_20250709_100000.json
[2025-07-09T10:00:02.000Z] CONVERT k88rs509-ise-report1: updated_at -> registry_updated_at
[2025-07-09T10:00:03.000Z] REMOVE k88rs509-ise-report1: status field deleted
[2025-07-09T10:00:04.000Z] MIGRATE COMPLETE: 45 entries processed
```

## 6. 今後の拡張計画

### 6.1 短期計画

1. **データ移行の実装**
   - 自動移行ツールの開発
   - 移行検証システムの構築

2. **バリデーション強化**
   - より厳密なデータ検証
   - 自動修復機能

### 6.2 中期計画

1. **メタデータ追加**
   - 作成者情報
   - 更新履歴
   - タグ機能

2. **外部システム連携**
   - 成績管理システム連携
   - 出席管理システム連携

### 6.3 長期計画

1. **データベース化**
   - SQLiteへの移行
   - 複雑なクエリ対応

2. **分散管理**
   - 複数インスタンス対応
   - 同期機能

## 7. 制約事項

### 7.1 技術的制約

- JSON形式での管理（現在）
- ファイルサイズ制限（GitHub API制限）
- 文字エンコーディング: UTF-8

### 7.2 運用制約

- 同時更新の制限
- バックアップの手動管理
- 大量データ処理の制限

## 8. 用語集

| 用語 | 説明 |
|------|------|
| レジストリ | 学生リポジトリ情報を管理するJSONファイル |
| エントリ | レジストリ内の1つのリポジトリ情報 |
| 移行 | 旧データ構造から新データ構造への変換 |
| 正規化 | データ形式の統一化 |
| ISO8601 | 国際標準の日時形式 |