# Registry Manager - Testing Strategy

**Last Updated**: 2025-07-03  
**Current Status**: 95 tests, 46.01% coverage (Target: 83%)

## Testing Philosophy

Registry Manager follows **Test-Driven Development (TDD)** principles with focus on:
- **Business Logic Coverage**: Core functionality thoroughly tested
- **Error Path Testing**: Comprehensive error scenario validation
- **Integration Testing**: End-to-end workflow verification
- **Mock Strategy**: Strategic use of mocks for external dependencies

## Current Testing Architecture

### Test Structure
```
test/
├── test_helper.exs                    # Test configuration
├── support/
│   └── github_api_mock.ex            # GitHub API mock implementation
└── registry_manager/
    ├── commands/
    │   └── status_test.exs           # Status command tests
    ├── repository/
    │   ├── repository_activity_enhancement_test.exs
    │   └── repository_business_logic_test.exs
    └── [module]_test.exs             # Various module tests
```

### Mock Strategy
- **GitHub API**: Complete mock with test data
- **File System**: Test fixtures for CSV data
- **User Input**: Captured I/O for interactive functions

## Module Testing Status

### ✅ Well Tested (80%+ Coverage)
- `RegistryManager.Commands.Status` (81.96%) - Status display logic
- `RegistryManager.Repository.Display` (100%) - Output formatting
- `RegistryManager.Repository.ErrorHandler` (100%) - Error handling

### ⚠️ Partially Tested (20-80% Coverage)
- `RegistryManager.Repository` (28.65%) - Core business logic
- `RegistryManager.Repository.DataStore` (51.61%) - Data persistence

### ❌ Untested (< 20% Coverage)
- `RegistryManager.CLI` (0%) - Command-line interface
- `RegistryManager` (0%) - Main module delegates
- `RegistryManager.GitHubAPI` (14.71%) - External API integration
- `RegistryManager.Validation` (19.30%) - Data validation

## Testing Gaps Analysis

### 1. CLI Interface Testing Gap
**Problem**: CLI module is completely untested due to `System.halt/1` calls
**Impact**: User interface reliability unclear
**Solution**:
```elixir
# Current (untestable)
def main(args) do
  case process(args) do
    {:ok, message} -> IO.puts(message)
    {:error, message} -> 
      IO.puts("Error: #{message}")
      System.halt(1)  # ← Makes testing difficult
  end
end

# Improved (testable)
def main(args) do
  case process(args) do
    {:ok, message} -> 
      IO.puts(message)
      {:ok, message}
    {:error, message} -> 
      IO.puts("Error: #{message}")
      {:error, message}
  end
end

def run(args) do
  case main(args) do
    {:ok, _} -> :ok
    {:error, _} -> System.halt(1)
  end
end
```

### 2. GitHub API Integration Testing Gap
**Problem**: Over-reliance on mocks prevents testing actual implementation
**Impact**: HTTP communication, authentication, error handling untested
**Solution**:
```elixir
# Add integration tests with HTTP stubbing
test "handles GitHub API authentication failure" do
  with_mock(System, [:passthrough], [cmd: fn("gh", ["auth", "token"], _) -> {"", 1} end]) do
    assert {:error, "GitHub CLI authentication failed. Run 'gh auth login'"} = 
           GitHubAPI.get_repositories_json()
  end
end

test "handles GitHub API rate limiting" do
  # Use bypass or similar for HTTP response stubbing
  bypass = Bypass.open()
  Bypass.expect(bypass, "GET", "/repos/smkwlab/thesis-student-registry/contents/data/repositories.json", fn conn ->
    Plug.Conn.resp(conn, 403, ~s({"message": "API rate limit exceeded"}))
  end)
  # Test rate limit handling
end
```

### 3. CSV Processing Testing Gap
**Problem**: CSV parsing and GitHub username extraction completely untested
**Impact**: Data migration and legacy support reliability unclear
**Solution**:
```elixir
describe "CSV processing" do
  test "extracts GitHub username from valid CSV" do
    csv_content = """
    Header1,Header2,StudentID,Col4,Col5,Col6,Col7,GitHubUsername
    data1,data2,k21rs001,data4,data5,data6,data7,test-user
    """
    
    assert {:ok, "test-user"} = Repository.get_github_username_from_csv("k21rs001")
  end

  test "handles missing GitHub username in CSV" do
    csv_content = """
    Header1,Header2,StudentID,Col4,Col5,Col6,Col7,GitHubUsername
    data1,data2,k21rs001,data4,data5,data6,data7,
    """
    
    assert {:error, "Student not found in CSV"} = Repository.get_github_username_from_csv("k21rs001")
  end
end
```

### 4. User Interaction Testing Gap
**Problem**: Interactive functions like deletion confirmation untested
**Impact**: User experience and safety mechanisms unclear
**Solution**:
```elixir
import ExUnit.CaptureIO

test "deletion confirmation prompts user correctly" do
  io_input = "yes\n"
  
  result = capture_io([input: io_input, capture_prompt: true], fn ->
    assert true = Repository.prompt_for_deletion_confirmation("test-repo")
  end)
  
  assert result =~ "Are you sure you want to proceed?"
  assert result =~ "Type 'yes' to confirm"
end

test "deletion confirmation rejects invalid input" do
  io_input = "no\n"
  
  capture_io([input: io_input], fn ->
    assert false = Repository.prompt_for_deletion_confirmation("test-repo")
  end)
end
```

## Testing Best Practices

### 1. Test Organization
```elixir
defmodule RegistryManager.RepositoryTest do
  use ExUnit.Case
  
  describe "add/4" do
    test "creates new repository entry with valid data" do
      # Test happy path
    end
    
    test "returns error for invalid student ID" do
      # Test validation error
    end
    
    test "handles GitHub username fetch failure gracefully" do
      # Test external service failure
    end
  end
  
  describe "update/4" do
    # Grouped tests for update functionality
  end
end
```

### 2. Mock Usage Guidelines
- **Use mocks sparingly**: Only for external dependencies (GitHub API, file system)
- **Test real logic**: Mock at boundaries, test business logic
- **Verify interactions**: Ensure mocks are called correctly

### 3. Test Data Management
```elixir
# Use consistent test data
@test_repository_data %{
  "k21rs001-sotsuron" => %{
    "student_id" => "k21rs001",
    "repository_type" => "sotsuron",
    "created_at" => "2025-01-01T00:00:00Z",
    "registry_updated_at" => "2025-01-01T00:00:00Z",
    "protection_status" => "protected",
    "github_username" => "test-taro"
  }
}
```

### 4. Error Testing Patterns
```elixir
test "handles all error scenarios" do
  # Network errors
  assert {:error, _} = function_under_test(:network_error)
  
  # Validation errors
  assert {:error, _} = function_under_test(:invalid_input)
  
  # Business logic errors
  assert {:error, _} = function_under_test(:business_rule_violation)
end
```

## Coverage Improvement Roadmap

### Phase 1: Foundation (Target: 55% coverage)
1. **CLI Module Refactoring**
   - Separate testable logic from `System.halt`
   - Add argument parsing tests
   - Test help text generation

2. **Repository Core Testing**
   - Add CSV processing tests
   - Test user interaction functions
   - Cover error handling paths

### Phase 2: Integration (Target: 70% coverage)
3. **GitHub API Testing**
   - HTTP response stubbing
   - Authentication flow testing
   - Error scenario coverage

4. **Validation Comprehensive Testing**
   - Boundary value testing
   - Error case enumeration
   - Edge case validation

### Phase 3: Excellence (Target: 83% coverage)
5. **End-to-End Testing**
   - Complete workflow testing
   - Integration test suite
   - Performance testing

## Tools and Libraries

### Current Stack
- **ExUnit**: Primary testing framework
- **Jason**: JSON manipulation in tests
- **Custom Mocks**: GitHub API simulation

### Recommended Additions
- **Mox**: More sophisticated mocking
- **Bypass**: HTTP endpoint stubbing
- **ExCoveralls**: Enhanced coverage reporting
- **StreamData**: Property-based testing

### Example Tool Usage
```elixir
# mix.exs
defp deps do
  [
    {:mox, "~> 1.0", only: :test},
    {:bypass, "~> 2.1", only: :test},
    {:stream_data, "~> 0.5", only: [:test, :dev]}
  ]
end

# In tests
use ExUnitProperties

property "validates student IDs correctly" do
  check all student_id <- student_id_generator() do
    result = Validation.validate_student_id(student_id)
    assert match?({:ok, _} | {:error, _}, result)
  end
end
```

## Quality Gates

### Pre-commit Checks
```bash
# Required checks before committing
mix test
mix test --cover
mix credo --strict
mix dialyzer
```

### CI/CD Pipeline
```yaml
# .github/workflows/test.yml
- name: Run tests with coverage
  run: |
    mix test --cover
    mix test --cover --export-coverage default
    
- name: Check coverage threshold
  run: |
    if [ $(mix test --cover | grep "Total" | awk '{print $2}' | sed 's/%//') -lt 83 ]; then
      echo "Coverage below threshold"
      exit 1
    fi
```

### Coverage Monitoring
- **Weekly Reports**: Track coverage trends
- **PR Requirements**: New code must maintain/improve coverage
- **Module Standards**: All new modules must start with 80%+ coverage

## Conclusion

The testing strategy focuses on systematic improvement of the lowest-coverage, highest-impact modules. By addressing CLI testability, enhancing GitHub API integration testing, and completing validation coverage, we can achieve the 83% target while maintaining code quality and reliability.

Key success factors:
1. **Incremental Improvement**: Phase-based approach
2. **Strategic Mocking**: Test real logic, mock boundaries
3. **Comprehensive Error Testing**: Cover all failure scenarios
4. **Automation**: Enforce quality gates in CI/CD pipeline