# Registry Manager

thesis-student-registry のリポジトリ情報を GitHub API 経由で管理する Elixir escript。

## 特徴

- **GitHub API 統合**: GitHub API 経由での安全なデータ操作
- **原子性**: GitHub のバージョン管理による安全な更新
- **型安全性**: Elixir の pattern matching でデータ整合性確保
- **一貫性**: thesis-monitor と同じアーキテクチャ

## インストール

```bash
# 依存関係のインストール
mix deps.get

# コンパイル
mix compile

# Escript のビルド
mix escript.build
```

## 使用方法

### 基本コマンド

```bash
# リポジトリ情報追加
./registry-manager add k21rs001-sotsuron k21rs001 sotsuron active thesis

# ブランチ保護設定完了マーク
./registry-manager protect k21rs001-sotsuron

# ステータス更新
./registry-manager update k21rs001-sotsuron status completed

# 統計表示
./registry-manager status

# リポジトリ一覧
./registry-manager list
./registry-manager list active  # フィルタ付き
```

### オプション

```bash
# ドライランモード（実際の変更なし）
./registry-manager add k21rs001-sotsuron k21rs001 sotsuron active --dry-run

# 詳細ログ表示
./registry-manager add k21rs001-sotsuron k21rs001 sotsuron active --verbose

# ヘルプ表示
./registry-manager --help
```

## データ構造

管理対象: `thesis-student-registry/data/repositories.json`

```json
{
  "k21rs001-sotsuron": {
    "student_id": "k21rs001",
    "repository_type": "sotsuron",
    "status": "active",
    "stage": "thesis",
    "updated_at": "2025-06-26 10:30:37 UTC",
    "protection_status": "protected"
  }
}
```

## 前提条件

- Elixir >= 1.14
- GitHub CLI (認証済み)
- thesis-student-registry リポジトリへの書き込み権限

## 開発

```bash
# テスト実行
mix test

# コード品質チェック
mix credo
mix dialyzer

# フォーマット
mix format
```

## アーキテクチャ

- `RegistryManager.CLI`: コマンドライン処理
- `RegistryManager.Repository`: リポジトリ情報管理ロジック
- `RegistryManager.GitHubAPI`: GitHub API クライアント

## 従来の bash スクリプトからの移行

### 旧 `update-repository-registry.sh`

```bash
# 旧方式（危険：ローカルファイル直接操作）
./update-repository-registry.sh add k21rs001-sotsuron k21rs001 sotsuron active
```

### 新 `registry-manager`

```bash
# 新方式（安全：GitHub API 経由）
./registry-manager add k21rs001-sotsuron k21rs001 sotsuron active
```

### 利点

1. **データ整合性**: GitHub のバージョン管理
2. **並行安全性**: API レベルでの競合回避
3. **監査性**: すべての変更が Git 履歴に記録
4. **エラーハンドリング**: Elixir の堅牢なエラー処理

