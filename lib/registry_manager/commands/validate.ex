defmodule RegistryManager.Commands.Validate do
  @moduledoc """
  Data validation command implementation for registry-manager v4.

  Validates registry data integrity including:
  - Student ID format validation
  - Repository name consistency
  - Repository type validation
  - Timestamp field validation
  - review_flow validation (required boolean)
  - Protection status validation
  - Legacy format detection

  Deprecated fields (status / stage / updated_at) are reported as legacy warnings.
  """

  alias RegistryManager.{GitHubAPI, TimestampManager, Validation}

  @doc """
  Runs the validate command with given arguments and options.

  ## Arguments
  - `args`: Optional repository name to validate specific entry

  ## Options
  - `verbose` (boolean): Show detailed validation information
  - `format` (string): Output format (table, json, csv)

  ## Test Parameters (for testing only)
  - `repositories` (map): Override repository data
  - `test_mode` (boolean): Use test mode for GitHub API
  """
  @spec run(list(String.t()), keyword(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, opts, test_params \\ []) do
    case args do
      [] -> validate_all(opts, test_params)
      [repo_name] -> validate_single(repo_name, opts, test_params)
      _ -> {:error, "Too many arguments. Usage: validate [repository_name]"}
    end
  end

  defp validate_all(opts, test_params) do
    with {:ok, repositories} <- get_repositories(test_params),
         {:ok, validation_results} <- perform_validation(repositories, opts),
         {:ok, output} <- format_results(validation_results, opts, test_params) do
      {:ok, output}
    end
  end

  defp validate_single(repo_name, opts, test_params) do
    with {:ok, repositories} <- get_repositories(test_params),
         {:ok, repo_data} <- get_single_repository(repositories, repo_name),
         {:ok, validation_result} <- validate_single_entry(repo_name, repo_data, opts),
         {:ok, output} <-
           format_single_result(
             repo_name,
             validation_result,
             Keyword.put(opts, :test_params, test_params)
           ) do
      {:ok, output}
    end
  end

  defp get_repositories(test_params) do
    case Keyword.get(test_params, :repositories) do
      nil ->
        # 実際のGitHub APIから取得
        case GitHubAPI.get_repositories_json() do
          {:ok, {data, _sha}} -> {:ok, data}
          {:error, reason} -> {:error, "Failed to fetch repositories: #{reason}"}
        end

      test_repos ->
        {:ok, test_repos}
    end
  end

  defp get_single_repository(repositories, repo_name) do
    case Map.get(repositories, repo_name) do
      nil -> {:error, "Repository not found: #{repo_name}"}
      data -> {:ok, data}
    end
  end

  defp perform_validation(repositories, opts) do
    verbose = Keyword.get(opts, :verbose, false)

    results =
      repositories
      |> Enum.map(fn {repo_name, data} ->
        if verbose do
          IO.puts("Checking entry: #{repo_name}")
        end

        result = validate_entry(repo_name, data)

        if verbose do
          print_verbose_result(repo_name, result)
        end

        {repo_name, result}
      end)
      |> Enum.into(%{})

    {:ok, results}
  end

  defp validate_entry(repo_name, data) do
    validations = [
      validate_required_fields(data),
      validate_student_id(data),
      validate_repository_name(repo_name, data),
      validate_repository_type(data),
      validate_timestamps(data),
      validate_review_flow(data),
      validate_protection_status(data),
      check_legacy_format(data)
    ]

    errors =
      validations
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn {:error, reason} -> reason end)

    warnings =
      validations
      |> Enum.filter(&match?({:warning, _}, &1))
      |> Enum.map(fn {:warning, reason} -> reason end)

    cond do
      not Enum.empty?(errors) -> {:invalid, errors}
      not Enum.empty?(warnings) -> {:legacy, warnings}
      true -> :valid
    end
  end

  defp validate_required_fields(data) do
    required = ["student_id", "repository_type"]

    missing =
      Enum.filter(required, fn field ->
        is_nil(Map.get(data, field)) or Map.get(data, field) == ""
      end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_student_id(data) do
    case Map.get(data, "student_id") do
      nil -> {:error, "Missing student_id"}
      id -> Validation.validate_student_id(id)
    end
  end

  defp validate_repository_name(repo_name, data) do
    case Map.get(data, "student_id") do
      nil -> {:error, "Cannot validate repository name without student_id"}
      id -> Validation.validate_repository_name(repo_name, id)
    end
  end

  defp validate_repository_type(data) do
    case Map.get(data, "repository_type") do
      nil -> {:error, "Missing repository_type"}
      type -> Validation.validate_repository_type(type)
    end
  end

  # 現行スキーマのタイムスタンプ: created_at（リポジトリ作成時刻）と
  # registry_updated_at（レジストリ最終更新）。どちらも単独で成立し得るため
  # 「少なくとも一方」を要求する。旧 updated_at は再流入ガードとして警告する
  @timestamp_fields ["created_at", "registry_updated_at"]

  defp validate_timestamps(data) do
    present = Enum.filter(@timestamp_fields, &Map.has_key?(data, &1))
    legacy? = Map.has_key?(data, "updated_at")

    if Enum.empty?(present) and not legacy? do
      {:error, "No timestamp fields found"}
    else
      data
      |> validate_timestamp_formats(present)
      |> apply_legacy_warning(legacy?)
    end
  end

  defp apply_legacy_warning(:ok, true), do: {:warning, "Legacy updated_at field detected"}
  defp apply_legacy_warning(result, _legacy?), do: result

  defp validate_timestamp_formats(data, fields) do
    invalid_fields = Enum.filter(fields, &invalid_timestamp_field?(data, &1))

    if Enum.empty?(invalid_fields) do
      :ok
    else
      {:error, "Invalid timestamp format in fields: #{Enum.join(invalid_fields, ", ")}"}
    end
  end

  defp invalid_timestamp_field?(data, field) do
    case Map.get(data, field) do
      nil -> true
      value -> not valid_timestamp_format?(value)
    end
  end

  defp valid_timestamp_format?(value) do
    case TimestampManager.parse_github_time(value) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  # review_flow は必須の boolean（draft PR サイクル対象か）。
  # タイプからのフォールバック推論は行わない
  defp validate_review_flow(data) do
    case Map.get(data, "review_flow") do
      nil -> {:error, "Missing review_flow field"}
      value when is_boolean(value) -> :ok
      value -> {:error, "Invalid review_flow: #{inspect(value)} (expected: true or false)"}
    end
  end

  defp validate_protection_status(data) do
    case Map.get(data, "protection_status") do
      # オプショナルフィールド
      nil ->
        :ok

      "protected" ->
        :ok

      "not_protected" ->
        :ok

      value ->
        {:error, "Invalid protection status: #{value} (expected: protected or not_protected)"}
    end
  end

  defp check_legacy_format(data) do
    deprecated_fields = ["status", "stage"]
    found_deprecated = Enum.filter(deprecated_fields, &Map.has_key?(data, &1))

    if Enum.empty?(found_deprecated) do
      :ok
    else
      {:warning, "Legacy format: contains deprecated fields #{Enum.join(found_deprecated, ", ")}"}
    end
  end

  defp validate_single_entry(repo_name, data, _opts) do
    {:ok, validate_entry(repo_name, data)}
  end

  defp print_verbose_result(_repo_name, result) do
    case result do
      :valid ->
        IO.puts("  ✅ Valid")

      {:legacy, warnings} ->
        IO.puts("  ⚠️  Legacy format:")
        Enum.each(warnings, fn w -> IO.puts("     - #{w}") end)

      {:invalid, errors} ->
        IO.puts("  ❌ Invalid:")
        Enum.each(errors, fn e -> IO.puts("     - #{e}") end)
    end
  end

  defp format_results(validation_results, opts, _test_params) do
    format = Keyword.get(opts, :format, "table")

    case format do
      "table" -> format_table_output(validation_results, opts)
      "json" -> format_json_output(validation_results, opts)
      "csv" -> format_csv_output(validation_results, opts)
      _ -> {:error, "Invalid format: #{format}"}
    end
  end

  defp format_table_output(validation_results, _opts) do
    stats = calculate_stats(validation_results)

    header = build_validation_header(stats)
    details = build_validation_details(validation_results, stats)
    summary = build_validation_summary(stats)

    {:ok, header <> details <> summary}
  end

  defp build_validation_header(stats) do
    """
    Validation Report
    =================

    Total entries: #{stats.total}
    Valid entries: #{stats.valid}
    Invalid entries: #{stats.invalid}
    Legacy entries: #{stats.legacy}
    """
  end

  defp build_validation_details(actual_results, stats) do
    if stats.invalid > 0 or stats.legacy > 0 do
      format_issues(actual_results)
    else
      ""
    end
  end

  defp build_validation_summary(stats) do
    cond do
      stats.invalid > 0 and stats.legacy > 0 -> "\n❌ Multiple validation errors found"
      stats.invalid > 0 -> "\n❌ Multiple validation errors found"
      stats.legacy > 0 -> "\n⚠️  Issues found"
      true -> "\n✅ All entries are valid"
    end
  end

  defp calculate_stats(results) do
    Enum.reduce(results, %{total: 0, valid: 0, invalid: 0, legacy: 0}, fn {_name, result}, acc ->
      acc = Map.update!(acc, :total, &(&1 + 1))

      case result do
        :valid -> Map.update!(acc, :valid, &(&1 + 1))
        {:invalid, _} -> Map.update!(acc, :invalid, &(&1 + 1))
        {:legacy, _} -> Map.update!(acc, :legacy, &(&1 + 1))
      end
    end)
  end

  defp format_issues(results) do
    invalid_entries =
      results
      |> Enum.filter(fn {_name, result} -> match?({:invalid, _}, result) end)
      |> Enum.map(fn {name, {:invalid, errors}} ->
        error_lines = Enum.map(errors, fn e -> "    - #{e}" end) |> Enum.join("\n")
        "  #{name}:\n#{error_lines}"
      end)

    legacy_entries =
      results
      |> Enum.filter(fn {_name, result} -> match?({:legacy, _}, result) end)
      |> Enum.map(fn {name, {:legacy, warnings}} ->
        warning_lines = Enum.map(warnings, fn w -> "    - #{w}" end) |> Enum.join("\n")
        "  #{name}:\n#{warning_lines}"
      end)

    sections = []

    sections =
      if Enum.empty?(invalid_entries) do
        sections
      else
        sections ++ ["\nInvalid Entries:\n" <> Enum.join(invalid_entries, "\n")]
      end

    sections =
      if Enum.empty?(legacy_entries) do
        sections
      else
        sections ++ ["\nLegacy Entries:\n" <> Enum.join(legacy_entries, "\n")]
      end

    Enum.join(sections, "\n")
  end

  defp format_single_result(repo_name, result, opts) do
    with {:ok, repositories} <- get_repositories(Keyword.get(opts, :test_params, [])),
         {:ok, repo_data} <- get_single_repository(repositories, repo_name) do
      header = """
      Validation Report for #{repo_name}
      ========================================

      Repository Information:
        Student ID: #{Map.get(repo_data, "student_id", "N/A")}
        Repository Type: #{Map.get(repo_data, "repository_type", "N/A")}
        GitHub Username: #{Map.get(repo_data, "github_username", "N/A")}

      """

      {:ok, header <> format_validation_status(result)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_validation_status(:valid), do: "✅ Entry is valid"

  defp format_validation_status({:invalid, errors}) do
    error_lines = Enum.map_join(errors, "\n", fn e -> "  - #{e}" end)
    "❌ Entry is invalid:\n#{error_lines}"
  end

  defp format_validation_status({:legacy, warnings}) do
    warning_lines = Enum.map_join(warnings, "\n", fn w -> "  - #{w}" end)
    "⚠️  Entry uses legacy format:\n#{warning_lines}"
  end

  defp format_json_output(validation_results, _opts) do
    stats = calculate_stats(validation_results)

    errors =
      validation_results
      |> Enum.filter(fn {_name, result} -> match?({:invalid, _}, result) end)
      |> Enum.map(fn {name, {:invalid, errors}} ->
        %{"repository" => name, "errors" => errors}
      end)

    legacy =
      validation_results
      |> Enum.filter(fn {_name, result} -> match?({:legacy, _}, result) end)
      |> Enum.map(fn {name, {:legacy, warnings}} ->
        %{"repository" => name, "warnings" => warnings}
      end)

    output = %{
      "total_entries" => stats.total,
      "valid_entries" => stats.valid,
      "invalid_entries" => stats.invalid,
      "legacy_entries" => stats.legacy,
      "errors" => errors,
      "legacy_details" => legacy
    }

    case Jason.encode(output, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, "JSON encoding failed: #{inspect(reason)}"}
    end
  end

  defp format_csv_output(validation_results, _opts) do
    header = "repository,status,issues"

    rows =
      validation_results
      |> Enum.map(fn {name, result} ->
        {status, issues} =
          case result do
            :valid -> {"valid", ""}
            {:invalid, errors} -> {"invalid", Enum.join(errors, "; ")}
            {:legacy, warnings} -> {"legacy", Enum.join(warnings, "; ")}
          end

        "#{name},#{status},#{escape_csv(issues)}"
      end)

    {:ok, ([header] ++ rows) |> Enum.join("\n")}
  end

  defp escape_csv(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"#{String.replace(value, "\"", "\"\"")}\""
    else
      value
    end
  end
end
