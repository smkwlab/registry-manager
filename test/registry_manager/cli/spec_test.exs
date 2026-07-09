defmodule RegistryManager.CLI.SpecTest do
  use ExUnit.Case, async: true

  alias RegistryManager.CLI.Spec

  describe "catalog integrity" do
    test "repo_types is the single source of repository types" do
      assert Spec.repo_types() == ["wr", "ise", "sotsuron", "master", "thesis", "latex", "other"]
    end

    test "pr states and sort keys are exposed as canonical lists" do
      assert Spec.pr_states() == ["open", "closed", "all"]
      assert Spec.pr_sort_keys() == ["repository", "updated", "created"]
    end

    test "every CLI dispatch command has a spec entry" do
      for name <- RegistryManager.CLI.known_commands() do
        assert Spec.find_command(name), "no spec for command #{name}"
      end
    end

    test "every spec command is dispatchable by the CLI" do
      known = MapSet.new(RegistryManager.CLI.known_commands())

      for command <- Spec.commands() do
        assert MapSet.member?(known, command.name),
               "spec command #{command.name} is not dispatchable"
      end
    end

    test "aliases are unique" do
      aliases = Keyword.keys(Spec.aliases())
      assert aliases == Enum.uniq(aliases)
    end

    test "command aliases resolve to their command" do
      assert Spec.find_command("ls").name == "list"
      assert Spec.find_command("rm").name == "remove"
      assert Spec.find_command("cache-status").name == "cache"
      assert Spec.find_command("unknown") == nil
    end

    test "strict switches cover every option referenced by a command" do
      switch_names = Keyword.keys(Spec.strict_switches()) |> MapSet.new()

      for command <- Spec.commands(), option <- Spec.options_for(command) do
        assert MapSet.member?(switch_names, option.name),
               "option #{option.name} of #{command.name} missing from strict switches"
      end
    end
  end

  describe "allowed_for/1" do
    test "global options are allowed for every command" do
      for command <- Spec.commands() do
        allowed = Spec.allowed_for(command.name)
        assert MapSet.member?(allowed, :help)
        assert MapSet.member?(allowed, :verbose)
      end
    end

    test "command-local options are not allowed elsewhere" do
      refute MapSet.member?(Spec.allowed_for("add"), :format)
      refute MapSet.member?(Spec.allowed_for("list"), :state)
      refute MapSet.member?(Spec.allowed_for("remove"), :force)
      assert MapSet.member?(Spec.allowed_for("list"), :format)
      assert MapSet.member?(Spec.allowed_for("pr-status"), :state)
    end

    test "returns nil for unknown commands" do
      assert Spec.allowed_for("unknown") == nil
    end
  end

  describe "validate_opts/2" do
    test "accepts valid options and enum values" do
      assert :ok = Spec.validate_opts("list", format: "json", type: "wr")
    end

    test "rejects options that do not belong to the command" do
      assert {:error, message} = Spec.validate_opts("add", format: "json")
      assert message =~ "--format"
      assert message =~ "add"
    end

    test "rejects invalid enum values" do
      assert {:error, message} = Spec.validate_opts("list", type: "bogus")
      assert message =~ "bogus"
      assert message =~ "wr"
    end

    test "propagate-workflow --type is enum-validated" do
      assert :ok = Spec.validate_opts("propagate-workflow", all: true, type: "thesis")
      assert {:error, _} = Spec.validate_opts("propagate-workflow", all: true, type: "bogus")
    end

    test "reports all violations at once" do
      assert {:error, message} = Spec.validate_opts("list", type: "bogus", state: "open")
      assert message =~ "--type"
      assert message =~ "--state"
    end

    test "sort keys are validated per command" do
      assert :ok = Spec.validate_opts("list", sort: "time")
      assert :ok = Spec.validate_opts("list", sort: "name")
      assert {:error, message} = Spec.validate_opts("list", sort: "updated")
      assert message =~ "name, time"

      assert :ok = Spec.validate_opts("pr-status", sort: "updated")
      assert {:error, _} = Spec.validate_opts("pr-status", sort: "time")
    end

    test "unknown command passes through (dispatch handles it)" do
      assert :ok = Spec.validate_opts("unknown", format: "json")
    end
  end

  describe "help rendering" do
    test "global help mentions every command and its options" do
      help = Spec.render_help()

      for command <- Spec.commands() do
        assert help =~ command.name

        for option <- Spec.options_for(command) do
          name = Atom.to_string(option.name)

          rendered =
            if String.length(name) == 1 do
              "-#{name}"
            else
              "--#{String.replace(name, "_", "-")}"
            end

          assert help =~ rendered, "help misses #{rendered} of #{command.name}"
        end
      end
    end

    test "command help shows only that command's options" do
      help = Spec.render_command_help("pr-status")

      assert help =~ "--state"
      assert help =~ "--review-requested"
      refute help =~ "--sort-by-time"
      refute help =~ "--delete-github-repo"
    end

    test "command help resolves aliases" do
      assert Spec.render_command_help("ls") == Spec.render_command_help("list")
      assert Spec.render_command_help("unknown") == nil
    end
  end
end
