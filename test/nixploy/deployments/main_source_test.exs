defmodule Nixploy.Deployments.MainSourceTest do
  use ExUnit.Case, async: true

  alias Nixploy.Deployments.{DeploymentInput, MainSource}
  alias Nixploy.ManagedApplications.Application

  test "accepts exactly one full refs/heads/main result" do
    oid = String.duplicate("a", 40)
    assert {:ok, ^oid} = MainSource.parse_resolution("#{oid}\trefs/heads/main\n")

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

  defp git!(directory, args) do
    {output, 0} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
