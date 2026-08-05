defmodule Nixploy.Deployments.MainSourceTest do
  use ExUnit.Case, async: true

  alias Nixploy.Deployments.{DeploymentInput, MainSource}
  alias Nixploy.Execution
  alias Nixploy.Execution.Result
  alias Nixploy.ManagedApplications.Application

  test "accepts exactly one full refs/heads/main result" do
    oid = String.duplicate("a", 40)
    assert {:ok, ^oid} = MainSource.parse_resolution("#{oid}\trefs/heads/main\n")
    assert {:ok, ^oid} = MainSource.parse_local_resolution("#{oid}\n")

    assert {:error, :main_resolution_malformed} =
             MainSource.parse_resolution("abc\trefs/heads/main\n")

    assert {:error, :main_resolution_ambiguous} =
             MainSource.parse_resolution("#{oid}\trefs/heads/main\n#{oid}\trefs/heads/main\n")

    assert {:error, :main_resolution_ambiguous} =
             MainSource.parse_resolution("#{oid}\tHEAD\n")
  end

  @tag :nix
  test "resolves, checks out and materializes the persisted object with real Git and Nix" do
    root =
      Path.join(System.tmp_dir!(), "nixploy-main-source-#{System.unique_integer([:positive])}")

    source = Path.join(root, "working")
    remote = Path.join(root, "remote.git")
    workspace = Path.join(root, "workspace")
    fixture = Path.expand("test/fixtures/local_store_flake")
    on_exit(fn -> File.rm_rf(root) end)

    File.mkdir_p!(source)
    File.cp_r!(fixture, source)
    git!(source, ["init", "--initial-branch=main"])
    git!(source, ["config", "user.email", "fixture@example.test"])
    git!(source, ["config", "user.name", "Fixture"])
    git!(source, ["add", "flake.nix", "flake.lock"])
    git!(source, ["commit", "-m", "bounded fixture release"])
    oid = git!(source, ["rev-parse", "HEAD"])
    {_output, 0} = System.cmd("git", ["clone", "--bare", source, remote], stderr_to_stdout: true)

    application = %Application{
      key: "fixture",
      project: "local-store-tracer",
      target: "production",
      repository: remote,
      repository_identity: "fixture/repository"
    }

    input = %DeploymentInput{
      id: Ecto.UUID.generate(),
      application_key: "fixture",
      source_revision: oid,
      source_ref: "refs/heads/main",
      selected_target: "production",
      state: :staging
    }

    assert {:ok, ^oid} = MainSource.resolve_main(application)

    assert {:ok, result} =
             MainSource.materialize(input, application,
               workspace_root: workspace,
               retain: fn id, store_path, _execute, _opts ->
                 assert id == input.id
                 assert String.starts_with?(store_path, "/nix/store/")
                 :ok
               end
             )

    assert String.starts_with?(result.store_path, "/nix/store/")
    assert String.starts_with?(result.nar_hash, "sha256-")
    assert result.commit_subject == "bounded fixture release"
    assert result.commit_timestamp
    assert result.derived_snapshot["project"] == "local-store-tracer"
    assert result.derived_snapshot["target"]["name"] == "production"
    assert byte_size(result.configuration_digest) == 64
    refute File.exists?(Path.join(workspace, input.id))
  end

  test "reads local main and snapshots the persisted commit despite checkout dirt and main advancement" do
    %{root: root, source: source, application: application, input: input, oid: oid} =
      source_fixture("dirty-advance")

    on_exit(fn -> File.rm_rf(root) end)

    git!(source, ["checkout", "-b", "work-in-progress"])
    File.write!(Path.join(source, "untracked.txt"), "not committed\n")
    File.write!(Path.join(source, "flake.nix"), "dirty worktree\n")

    assert {:ok, ^oid} = MainSource.resolve_main(application)

    git!(source, ["checkout", "main"])
    File.write!(Path.join(source, "advance.txt"), "new main\n")
    git!(source, ["add", "advance.txt"])
    git!(source, ["commit", "-m", "advance main after persistence"])
    git!(source, ["checkout", "work-in-progress"])

    status_before = git!(source, ["status", "--porcelain=v1", "--untracked-files=all"])
    refs_before = git!(source, ["show-ref"])

    assert {:ok, result} = materialize(input, application, root)
    assert result.commit_subject == "bounded dirty-advance release"
    assert git!(source, ["status", "--porcelain=v1", "--untracked-files=all"]) == status_before
    assert git!(source, ["show-ref"]) == refs_before
    refute File.exists?(Path.join([root, "workspace", input.id]))
  end

  test "rejects committed LFS pointers without contacting an LFS server" do
    %{root: root, source: source, application: application, input: input} =
      source_fixture("lfs")

    on_exit(fn -> File.rm_rf(root) end)

    File.write!(
      Path.join(source, "large.bin"),
      "version https://git-lfs.github.com/spec/v1\noid sha256:#{String.duplicate("a", 64)}\nsize 1\n"
    )

    git!(source, ["add", "large.bin"])
    git!(source, ["commit", "-m", "add lfs pointer"])
    lfs_oid = git!(source, ["rev-parse", "HEAD"])

    assert {:error, :lfs_not_supported} =
             materialize(%{input | source_revision: lfs_oid}, application, root)

    refute File.exists?(Path.join([root, "workspace", input.id]))
  end

  test "rejects committed gitlinks even without a .gitmodules file" do
    %{root: root, source: source, application: application, input: input, oid: oid} =
      source_fixture("gitlink")

    on_exit(fn -> File.rm_rf(root) end)

    git!(source, ["update-index", "--add", "--cacheinfo", "160000,#{oid},vendor/dependency"])
    git!(source, ["commit", "-m", "add bare gitlink"])
    gitlink_oid = git!(source, ["rev-parse", "HEAD"])

    assert {:error, :submodules_not_supported} =
             materialize(%{input | source_revision: gitlink_oid}, application, root)

    refute File.exists?(Path.join([root, "workspace", input.id]))
  end

  test "rejects a symlinked flake subdirectory that escapes the snapshot" do
    %{root: root, source: source, application: application, input: input} =
      source_fixture("symlink")

    on_exit(fn -> File.rm_rf(root) end)

    File.ln_s!("/tmp", Path.join(source, "linked"))
    git!(source, ["add", "linked"])
    git!(source, ["commit", "-m", "add escaping subdirectory"])
    symlink_oid = git!(source, ["rev-parse", "HEAD"])

    assert {:error, :subdirectory_unsafe} =
             materialize(
               %{input | source_revision: symlink_oid},
               %{application | subdirectory: "linked"},
               root
             )

    refute File.exists?(Path.join([root, "workspace", input.id]))
  end

  test "startup cleanup removes only UUID-named abandoned workspaces" do
    root =
      Path.join(
        System.tmp_dir!(),
        "nixploy-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    abandoned = Ecto.UUID.generate()
    File.mkdir_p!(Path.join(root, abandoned))
    File.mkdir_p!(Path.join(root, "operator-notes"))
    on_exit(fn -> File.rm_rf(root) end)

    assert :ok = MainSource.cleanup_abandoned(root)
    refute File.exists?(Path.join(root, abandoned))
    assert File.dir?(Path.join(root, "operator-notes"))
  end

  test "uses bounded local ref argv and disables ambient Git configuration" do
    oid = String.duplicate("b", 40)
    parent = self()

    application = %Application{
      key: "fixture",
      project: "fixture",
      target: "production",
      repository: "/srv/repos/fixture",
      repository_identity: "fixture/repository"
    }

    execute = fn command, _opts ->
      send(parent, {:command, command})
      {:ok, %Result{exit_status: 0, output_tail: oid <> "\n", output_truncated?: false}}
    end

    assert {:ok, ^oid} = MainSource.resolve_main(application, execute: execute)
    assert_receive {:command, command}

    assert command.args == [
             "-c",
             "safe.directory=/srv/repos/fixture",
             "-C",
             "/srv/repos/fixture",
             "rev-parse",
             "--verify",
             "--end-of-options",
             "refs/heads/main^{commit}"
           ]

    assert command.env["GIT_TERMINAL_PROMPT"] == "0"
    assert command.env["GIT_CONFIG_NOSYSTEM"] == "1"
    assert command.env["GIT_CONFIG_GLOBAL"] == "/dev/null"
  end

  defp source_fixture(label) do
    root =
      Path.join(
        System.tmp_dir!(),
        "nixploy-main-source-#{label}-#{System.unique_integer([:positive])}"
      )

    source = Path.join(root, "working")
    fixture = Path.expand("test/fixtures/local_store_flake")

    File.mkdir_p!(source)
    File.cp_r!(fixture, source)
    git!(source, ["init", "--initial-branch=main"])
    git!(source, ["config", "user.email", "fixture@example.test"])
    git!(source, ["config", "user.name", "Fixture"])
    git!(source, ["add", "flake.nix", "flake.lock"])
    git!(source, ["commit", "-m", "bounded #{label} release"])
    oid = git!(source, ["rev-parse", "HEAD"])

    application = %Application{
      key: "fixture",
      project: "local-store-tracer",
      target: "production",
      repository: source,
      repository_identity: "fixture/repository"
    }

    input = %DeploymentInput{
      id: Ecto.UUID.generate(),
      application_key: "fixture",
      source_revision: oid,
      source_ref: "refs/heads/main",
      selected_target: "production",
      state: :staging
    }

    %{root: root, source: source, application: application, input: input, oid: oid}
  end

  defp materialize(input, application, root) do
    store_path = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source"
    nar_hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    execute = fn command, opts ->
      if Path.basename(command.executable) == "git" do
        Execution.run(command, opts)
      else
        output =
          case command.args do
            ["store", "add" | _rest] ->
              store_path <> "\n"

            ["path-info" | _rest] ->
              Jason.encode!(%{store_path => %{"narHash" => nar_hash}})

            ["eval" | _rest] ->
              Jason.encode!(%{
                "__schema" => "v0.2",
                "project" => "local-store-tracer",
                "targets" => %{
                  "production" => %{
                    "image" => "fixtureImage",
                    "ip" => "127.0.0.1",
                    "user" => "nixploy",
                    "port" => 22,
                    "identityFile" => nil,
                    "run" => %{
                      "command" => nil,
                      "environment" => %{},
                      "network" => "host",
                      "ports" => [],
                      "preStart" => []
                    },
                    "secrets" => %{},
                    "web" => %{
                      "domain" => "fixture.invalid",
                      "healthPath" => "/health",
                      "slots" => %{"blue" => 18_080, "green" => 18_081}
                    }
                  }
                }
              })
          end

        {:ok, %Result{exit_status: 0, output_tail: output, output_truncated?: false}}
      end
    end

    MainSource.materialize(input, application,
      workspace_root: Path.join(root, "workspace"),
      execute: execute,
      path_exists?: fn _path -> true end,
      retain: fn _id, _store_path, _execute, _opts -> :ok end
    )
  end

  defp git!(directory, args) do
    {output, 0} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
