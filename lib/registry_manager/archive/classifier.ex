defmodule RegistryManager.Archive.Classifier do
  @moduledoc """
  卒業処理の対象判定（純粋ロジック）。

  registry エントリと名簿エントリを学籍番号で結合し、`current_nendo`（現在の
  年度）を基準に各リポジトリを分類する。副作用は持たず、入力から出力を計算する
  だけなので全分岐を単体テストできる。

  ## 分類（`classification`）

  - `:graduated` — 卒業済み（archive 対象）
  - `:enrolled` — 在学中（対象外）
  - `:needs_review` — 要確認（名簿未突合・特殊学籍・年度情報なし）
  - `:already_archived` — 既に archive 済み（冪等）

  ## 判定ルール（上から優先、Issue #49）

  1. エントリに `archived_at` があれば `:already_archived`
  2. 学籍番号が特殊学籍（末尾 999 = テスト基盤、50x = staff テスト用）なら `:needs_review`
  3. 名簿と学籍番号で突合できなければ `:needs_review`
  4. 卒業判定（**修了年度を優先し、次に卒業年度**）:
     - 修了年度あり → `修了年度 < current_nendo` で `:graduated`、それ以外 `:enrolled`
     - 修了年度なし かつ 大学院学籍番号あり → `:enrolled`（院進補正: 在学中）
     - 卒業年度あり → `卒業年度 < current_nendo` で `:graduated`、それ以外 `:enrolled`
     - いずれの年度も無い → `:needs_review`

  年度は日本の年度（4 月始まり）。`卒業年度 == current_nendo` の学生はその年度の
  3 月に卒業予定のため、まだ在学中として扱う（`<` 比較）。
  """

  @type classification :: :graduated | :enrolled | :needs_review | :already_archived

  @type result :: %{
          repo: String.t(),
          repository_type: String.t() | nil,
          student_id: String.t() | nil,
          name: String.t() | nil,
          graduation_year: String.t() | nil,
          completion_year: String.t() | nil,
          classification: classification(),
          reason: String.t()
        }

  # 名簿エントリ（Repository.load_roster/0 が返す構造）
  @type roster_entry :: %{
          required(:student_ids) => [String.t()],
          optional(:name) => String.t() | nil,
          optional(:github) => String.t() | nil,
          optional(:graduation_year) => String.t() | nil,
          optional(:completion_year) => String.t() | nil,
          optional(:graduate_student_id) => String.t() | nil
        }

  @doc """
  日本の年度（4 月始まり）を返す。1〜3 月は前年が年度。
  """
  @spec current_nendo(Date.t()) :: integer()
  def current_nendo(date \\ Date.utc_today()) do
    if date.month >= 4, do: date.year, else: date.year - 1
  end

  @doc """
  registry 全体を名簿と結合して分類し、リポジトリ名でソートして返す。
  """
  @spec classify_all(map(), [roster_entry()], integer()) :: [result()]
  def classify_all(registry, roster, current_nendo)
      when is_map(registry) and is_list(roster) and is_integer(current_nendo) do
    index = build_roster_index(roster)

    registry
    |> Enum.map(fn {repo, data} -> classify_one(repo, data, index, current_nendo) end)
    |> Enum.sort_by(& &1.repo)
  end

  @doc """
  1 エントリ分の分類。`index` は正規化済み学籍番号 → 名簿エントリのマップ。
  """
  @spec classify_one(String.t(), map(), map(), integer()) :: result()
  def classify_one(repo, data, index, current_nendo) do
    student_id = Map.get(data, "student_id")
    roster = Map.get(index, normalize_student_id(student_id))
    base = base_result(repo, data, roster)

    cond do
      archived?(data) ->
        %{base | classification: :already_archived, reason: "既に archive 済み"}

      special_student_id?(student_id) ->
        %{base | classification: :needs_review, reason: "特殊学籍（テスト/staff）: #{student_id}"}

      is_nil(roster) ->
        %{base | classification: :needs_review, reason: "名簿と突合できません: #{student_id}"}

      true ->
        classify_by_year(base, roster, current_nendo)
    end
  end

  defp base_result(repo, data, roster) do
    %{
      repo: repo,
      repository_type: Map.get(data, "repository_type"),
      student_id: Map.get(data, "student_id"),
      name: roster && Map.get(roster, :name),
      graduation_year: roster && Map.get(roster, :graduation_year),
      completion_year: roster && Map.get(roster, :completion_year),
      classification: :needs_review,
      reason: ""
    }
  end

  # 修了年度を優先し、次に院進補正、最後に卒業年度を見る（Issue #49）
  defp classify_by_year(base, roster, current_nendo) do
    completion = parse_year(Map.get(roster, :completion_year))
    graduation = parse_year(Map.get(roster, :graduation_year))
    grad_student_id = presence(Map.get(roster, :graduate_student_id))

    cond do
      not is_nil(completion) ->
        by_threshold(base, completion, current_nendo, "修了年度")

      not is_nil(grad_student_id) ->
        # 院進補正: 大学院学籍番号があり修了年度が未設定 = 院在学中
        %{base | classification: :enrolled, reason: "院在学中（修了年度未設定）"}

      not is_nil(graduation) ->
        by_threshold(base, graduation, current_nendo, "卒業年度")

      true ->
        %{base | classification: :needs_review, reason: "年度情報がありません"}
    end
  end

  defp by_threshold(base, year, current_nendo, label) do
    if year < current_nendo do
      %{base | classification: :graduated, reason: "#{label} #{year} < 現年度 #{current_nendo}"}
    else
      %{base | classification: :enrolled, reason: "#{label} #{year} >= 現年度 #{current_nendo}"}
    end
  end

  # 正規化済み学籍番号 → 名簿エントリ。1 学生が学部/院の 2 番号を持つため両方を張る。
  defp build_roster_index(roster) do
    Enum.reduce(roster, %{}, fn entry, acc ->
      entry
      |> Map.get(:student_ids, [])
      |> Enum.map(&normalize_student_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(acc, fn id, inner -> Map.put_new(inner, id, entry) end)
    end)
  end

  defp archived?(data), do: presence(Map.get(data, "archived_at")) != nil

  # 学籍番号末尾の数字で特殊学籍を判定する（Issue #49）。
  # 番号部の桁数はタイプにより変わる（学部 3 桁 / 院 2 桁等）ため、末尾の数字列の
  # 下 3 桁を見る。999 = テスト基盤、500〜509 = staff テスト用。
  defp special_student_id?(nil), do: false

  defp special_student_id?(student_id) do
    case trailing_number(student_id) do
      nil -> false
      "999" -> true
      number -> Regex.match?(~r/^50\d$/, number)
    end
  end

  defp trailing_number(student_id) do
    case Regex.run(~r/(\d+)$/, student_id) do
      [_, digits] -> String.slice(digits, -3, 3)
      _ -> nil
    end
  end

  # "80JK059" -> "k80jk059"、"k80jk059" はそのまま（repository.ex の正規化と同一規約）
  defp normalize_student_id(nil), do: nil

  defp normalize_student_id(student_id) when is_binary(student_id) do
    case String.downcase(String.trim(student_id)) do
      "" -> nil
      "k" <> _ = normalized -> normalized
      id -> "k" <> id
    end
  end

  defp parse_year(value) do
    case presence(value) do
      nil ->
        nil

      str ->
        # "2024abc" のような末尾余剰付き文字列は年度として扱わない（不正値を弾く）
        case Integer.parse(str) do
          {year, ""} -> year
          _ -> nil
        end
    end
  end

  # 「空でない値」を返す。nil と空白のみの文字列は nil に潰す。
  # 主対象は名簿由来の文字列（学籍番号・年度・氏名）。バイナリ以外（想定外の型）は
  # 判定を壊さないようそのまま通す（呼び出し側は nil か否かだけを見る）。
  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(value), do: value
end
