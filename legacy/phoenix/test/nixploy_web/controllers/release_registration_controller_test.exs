defmodule NixployWeb.ReleaseRegistrationControllerTest do
  use NixployWeb.ConnCase, async: false

  import Ecto.Query

  alias Nixploy.Audit.Event
  alias Nixploy.Deployments.LocalStoreInput
  alias Nixploy.Execution.Result
  alias Nixploy.{Deployments, Fixtures, Repo}

  @token "ci-release-token-with-at-least-thirty-two-bytes"
  @store_path "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ci-release-source"
  @nar_hash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  @revision String.duplicate("a", 40)

  setup do
    operator = Fixtures.operator_fixture(%{email: "ci-release-owner@example.com"})
    previous_config = Application.get_env(:nixploy, :release_registration)
    previous_execute = Application.get_env(:nixploy, :release_registration_execute)
    previous_probe = Application.get_env(:nixploy, :local_store_input_probe)
    previous_workspace = Application.get_env(:nixploy, :release_registration_workspace_root)

    Application.put_env(:nixploy, :release_registration,
      token: @token,
      operator_email: operator.email,
      project: "jomat",
      target: "production",
      repository: "JonasThowsen/jomat"
    )

    Application.put_env(
      :nixploy,
      :release_registration_workspace_root,
      Path.join(System.tmp_dir!(), "nixploy-release-registration-test")
    )

    Application.put_env(:nixploy, :release_registration_execute, fn command, _opts ->
      send(self(), {:executed, command})
      {:ok, %Result{exit_status: 0, output_tail: @store_path <> "\n", output_truncated?: false}}
    end)

    Application.put_env(:nixploy, :local_store_input_probe, fn path, _opts ->
      assert path == @store_path

      {:ok,
       %LocalStoreInput.Source{
         store_path: path,
         nar_hash: @nar_hash,
         project: "jomat",
         targets: %{
           "production" => %{
             "name" => "production",
             "image_output" => "docker",
             "domain" => "jomat.no",
             "health_path" => "/health",
             "slots" => %{"blue" => 4002, "green" => 4003},
             "run" => %{
               "command" => nil,
               "pre_start" => [],
               "environment" => %{},
               "network" => "host",
               "ports" => []
             },
             "credential_references" => %{},
             "pre_start_declared" => false,
             "secrets_declared" => false
           }
         }
       }}
    end)

    on_exit(fn ->
      restore_env(:release_registration, previous_config)
      restore_env(:release_registration_execute, previous_execute)
      restore_env(:local_store_input_probe, previous_probe)
      restore_env(:release_registration_workspace_root, previous_workspace)
    end)

    :ok
  end

  test "imports, verifies, and stages a committed release without deploying", %{conn: conn} do
    jobs_before = Repo.aggregate(Oban.Job, :count)

    conn = conn |> registration_headers() |> post(~p"/api/releases", "nix-export")

    assert %{
             "data" => %{
               "id" => id,
               "state" => "staged",
               "project" => "jomat",
               "target" => "production",
               "nar_hash" => @nar_hash,
               "source_repository" => "JonasThowsen/jomat",
               "source_revision" => @revision,
               "disposition" => "created",
               "deployment_requested" => false,
               "release_url" => release_url
             }
           } = json_response(conn, 201)

    assert URI.parse(release_url).path == "/releases/#{id}"

    assert_received {:executed,
                     %{
                       executable: "nix-store",
                       args: ["--restore", restored_source],
                       stdin: "nix-export"
                     }}

    assert String.ends_with?(restored_source, "/source")

    assert_received {:executed,
                     %{
                       executable: "nix",
                       args: [
                         "store",
                         "add",
                         "--name",
                         "ci-release-source",
                         "--",
                         ^restored_source
                       ],
                       stdin: nil
                     }}

    input = Deployments.get_deployment_input!(id)
    assert input.registration_channel == :ci
    assert input.source_repository == "JonasThowsen/jomat"
    assert input.source_revision == @revision
    assert input.requested_by_operator.email == "ci-release-owner@example.com"
    assert Repo.aggregate(Oban.Job, :count) == jobs_before

    assert %Event{outcome: "succeeded", operator_id: operator_id, metadata: metadata} =
             Repo.get_by!(Event, action: "ci_release_registered", resource_id: id)

    assert operator_id == input.requested_by_operator_id
    assert metadata["revision"] == @revision
    assert metadata["nar_hash"] == @nar_hash
  end

  test "repeated delivery returns the existing immutable release", %{conn: conn} do
    first = conn |> registration_headers() |> post(~p"/api/releases", "nix-export")
    first_id = json_response(first, 201)["data"]["id"]

    second =
      Phoenix.ConnTest.build_conn()
      |> registration_headers()
      |> post(~p"/api/releases", "same-export")

    assert %{"data" => %{"id" => ^first_id, "disposition" => "existing"}} =
             json_response(second, 200)

    assert Repo.aggregate(
             from(input in Nixploy.Deployments.DeploymentInput,
               where: input.store_path == ^@store_path and input.state == :staged
             ),
             :count
           ) == 1
  end

  test "rejects an invalid bearer credential before importing", %{conn: conn} do
    conn =
      conn
      |> registration_headers("wrong-token-that-is-still-long-enough-to-check")
      |> post(~p"/api/releases", "nix-export")

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    refute_received {:executed, _command}
    assert Deployments.list_deployment_inputs() == []
  end

  test "persists an audited failure for an unauthorized project", %{conn: conn} do
    conn =
      conn
      |> registration_headers()
      |> put_req_header("x-nixploy-project", "other")
      |> post(~p"/api/releases", "nix-export")

    assert %{"error" => %{"code" => "invalid_project"}} = json_response(conn, 422)
    refute_received {:executed, _command}

    assert %Event{outcome: "failed", metadata: metadata} =
             Repo.get_by!(Event, action: "ci_release_registration_failed")

    assert metadata["project"] == "other"
    assert metadata["failure_code"] == "invalid_project"
  end

  test "rejects an oversized body from content length before importing", %{conn: conn} do
    conn =
      conn
      |> registration_headers()
      |> put_req_header("content-length", Integer.to_string(32 * 1_024 * 1_024 + 1))
      |> post(~p"/api/releases", "small-body")

    assert %{"error" => %{"code" => "export_too_large"}} = json_response(conn, 413)
    refute_received {:executed, _command}
  end

  defp registration_headers(conn, token \\ @token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/x-nix-nar")
    |> put_req_header("x-nixploy-store-path", @store_path)
    |> put_req_header("x-nixploy-nar-hash", @nar_hash)
    |> put_req_header("x-nixploy-project", "jomat")
    |> put_req_header("x-nixploy-target", "production")
    |> put_req_header("x-nixploy-repository", "JonasThowsen/jomat")
    |> put_req_header("x-nixploy-revision", @revision)
  end

  defp restore_env(key, nil), do: Application.delete_env(:nixploy, key)
  defp restore_env(key, value), do: Application.put_env(:nixploy, key, value)
end
