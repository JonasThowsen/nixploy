defmodule Nixploy.Deployments.LocalStoreInputTest do
  use ExUnit.Case, async: false

  alias Nixploy.Deployments.LocalStoreInput
  alias Nixploy.Execution.Result

  @store_path "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-local-store-fixture"
  @nar_hash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

  test "requires an existing canonical direct path under /nix/store" do
    exists = fn _path -> true end

    assert {:ok, @store_path} = LocalStoreInput.validate_store_path(@store_path, exists)
    assert {:error, :store_path_required} = LocalStoreInput.validate_store_path("", exists)

    assert {:error, :store_path_not_absolute} =
             LocalStoreInput.validate_store_path("relative-source", exists)

    assert {:error, :store_path_outside_nix_store} =
             LocalStoreInput.validate_store_path("/tmp/source", exists)

    assert {:error, :store_path_outside_nix_store} =
             LocalStoreInput.validate_store_path(@store_path <> "/nested", exists)

    assert {:error, :store_path_not_canonical} =
             LocalStoreInput.validate_store_path(" #{@store_path}", exists)

    assert {:error, :store_path_not_found} =
             LocalStoreInput.validate_store_path(@store_path, fn _path -> false end)
  end

  test "parses only the exact path and extracts the NAR hash returned by Nix" do
    output = Jason.encode!(%{@store_path => %{"narHash" => @nar_hash, "narSize" => 123}})

    assert {:ok, @nar_hash} = LocalStoreInput.parse_path_info(output, @store_path)

    assert {:error, :path_info_missing} =
             LocalStoreInput.parse_path_info(
               Jason.encode!(%{"/nix/store/other" => %{"narHash" => @nar_hash}}),
               @store_path
             )

    assert {:error, :nar_hash_missing} =
             LocalStoreInput.parse_path_info(
               Jason.encode!(%{@store_path => %{"narSize" => 123}}),
               @store_path
             )

    assert {:error, {:invalid_path_info_json, _detail}} =
             LocalStoreInput.parse_path_info("not-json", @store_path)

    assert {:error, {:invalid_nixploy_config_json, _detail}} =
             LocalStoreInput.parse_config("not-json")
  end

  test "requires schema v0.2 and normalizes only deployment fields" do
    assert {:ok, "fixture", targets} = LocalStoreInput.normalize_config(config())

    assert targets["production"] == %{
             "name" => "production",
             "image_output" => "fixtureImage",
             "domain" => "fixture.example.test",
             "health_path" => "/ready",
             "slots" => %{"blue" => 8080, "green" => 8081},
             "run" => %{
               "command" => nil,
               "pre_start" => [["/app/migrate"]],
               "environment" => %{},
               "network" => nil,
               "ports" => []
             },
             "pre_start_declared" => true,
             "secrets_declared" => true
           }

    refute Map.has_key?(targets["production"], "secrets")

    invalid_action = put_in(config(), ["targets", "production", "run", "preStart"], [[]])

    assert {:error, {:invalid_target, "production", "run.preStart[1]"}} =
             LocalStoreInput.normalize_config(invalid_action)

    nul_action =
      put_in(config(), ["targets", "production", "run", "preStart"], [["/app/migrate\0bad"]])

    assert {:error, {:invalid_target, "production", "run.preStart[1]"}} =
             LocalStoreInput.normalize_config(nul_action)

    assert {:error, {:unsupported_config_schema, "v0.1"}} =
             config()
             |> Map.put("__schema", "v0.1")
             |> LocalStoreInput.normalize_config()

    assert {:error, :config_schema_missing} =
             config()
             |> Map.delete("__schema")
             |> LocalStoreInput.normalize_config()
  end

  test "selects one derived target and rejects missing or ambiguous selection" do
    source = source(config())

    assert {:ok, target, snapshot} = LocalStoreInput.select_target(source, "production")
    assert target["image_output"] == "fixtureImage"
    assert snapshot["project"] == "fixture"
    assert snapshot["target"]["name"] == "production"

    assert {:error, {:flake_target_missing, "missing"}} =
             LocalStoreInput.select_target(source, "missing")

    second_target = get_in(config(), ["targets", "production"])
    ambiguous = put_in(config(), ["targets", "staging"], second_target)

    assert {:error, {:ambiguous_flake_targets, ["production", "staging"]}} =
             ambiguous |> source() |> LocalStoreInput.select_target(nil)

    assert {:ok, _target, only_snapshot} = LocalStoreInput.select_target(source, nil)
    assert only_snapshot["target"]["name"] == "production"
  end

  test "canonical digest is stable across map insertion order and changes with configuration" do
    first = %{
      "schema" => "v0.2",
      "project" => "fixture",
      "target" => %{"name" => "production", "slots" => %{"blue" => 8080, "green" => 8081}}
    }

    second = %{
      "target" => %{"slots" => %{"green" => 8081, "blue" => 8080}, "name" => "production"},
      "project" => "fixture",
      "schema" => "v0.2"
    }

    assert LocalStoreInput.digest(first) == LocalStoreInput.digest(second)
    assert byte_size(LocalStoreInput.digest(first)) == 64

    refute LocalStoreInput.digest(first) ==
             LocalStoreInput.digest(put_in(second, ["target", "slots", "green"], 8082))
  end

  test "uses fixed Nix argv with explicit time and output bounds" do
    parent = self()

    execute = fn command, opts ->
      send(parent, {:command, command, opts})

      case command.args do
        ["path-info" | _rest] -> ok_result(path_info_json())
        ["eval" | _rest] -> ok_result(Jason.encode!(config()))
      end
    end

    assert {:ok, inspected} =
             LocalStoreInput.probe(@store_path,
               execute: execute,
               path_exists?: fn _path -> true end,
               cancelled?: fn -> false end
             )

    assert inspected.nar_hash == @nar_hash

    assert_receive {:command, path_info, [cancelled?: cancelled?]}
    assert path_info.executable == "nix"

    assert path_info.args == [
             "path-info",
             "--json",
             "--json-format",
             "1",
             "--",
             @store_path
           ]

    assert path_info.timeout == 30_000
    assert path_info.max_output_bytes == 1_048_576
    refute cancelled?.()

    assert_receive {:command, eval, [cancelled?: _cancelled?]}

    assert eval.args == [
             "eval",
             "--json",
             "--no-write-lock-file",
             "#{@store_path}#nixploy"
           ]

    assert eval.timeout == 300_000
    assert eval.max_output_bytes == 1_048_576
    assert is_nil(eval.cd)
  end

  test "reports bounded output, timeout, and command failure without evaluating further" do
    assert {:error, :path_info_output_too_large} =
             LocalStoreInput.probe(@store_path,
               path_exists?: fn _path -> true end,
               execute: fn _command, _opts ->
                 {:ok,
                  %Result{
                    exit_status: 0,
                    output_tail: "{}",
                    output_truncated?: true
                  }}
               end
             )

    eval_too_large = fn command, _opts ->
      case command.args do
        ["path-info" | _rest] ->
          ok_result(path_info_json())

        ["eval" | _rest] ->
          {:ok,
           %Result{
             exit_status: 0,
             output_tail: "{}",
             output_truncated?: true
           }}
      end
    end

    assert {:error, :eval_output_too_large} =
             LocalStoreInput.probe(@store_path,
               path_exists?: fn _path -> true end,
               execute: eval_too_large
             )

    assert {:error, :path_info_timeout} =
             LocalStoreInput.probe(@store_path,
               path_exists?: fn _path -> true end,
               execute: fn _command, _opts -> {:error, :timeout} end
             )

    assert {:error, {:path_info_failed, 1, "path is not valid\n"}} =
             LocalStoreInput.probe(@store_path,
               path_exists?: fn _path -> true end,
               execute: fn _command, _opts ->
                 {:ok, %Result{exit_status: 1, output_tail: "path is not valid\n"}}
               end
             )
  end

  test "exercises the real Nix store verification and flake evaluation boundary" do
    nix = System.find_executable("nix") || flunk("nix executable is required")
    fixture = Path.expand("test/fixtures/local_store_flake")

    {store_path, 0} = System.cmd(nix, ["store", "add-path", fixture], stderr_to_stdout: true)
    store_path = String.trim(store_path)

    assert {:ok, inspected} = LocalStoreInput.probe(store_path)
    assert inspected.store_path == store_path
    assert String.starts_with?(inspected.nar_hash, "sha256-")
    assert inspected.project == "local-store-tracer"

    assert {:ok, target, snapshot} = LocalStoreInput.select_target(inspected, "production")
    assert target["image_output"] == "fixtureImage"
    assert target["slots"] == %{"blue" => 18_080, "green" => 18_081}
    assert target["run"]["pre_start"] == [["/bin/fixture-pre-start", "--prepare"]]
    assert snapshot["target"]["health_path"] == "/health"
  end

  defp source(config) do
    {:ok, project, targets} = LocalStoreInput.normalize_config(config)

    %LocalStoreInput.Source{
      store_path: @store_path,
      nar_hash: @nar_hash,
      project: project,
      targets: targets
    }
  end

  defp path_info_json, do: Jason.encode!(%{@store_path => %{"narHash" => @nar_hash}})

  defp ok_result(output) do
    {:ok, %Result{exit_status: 0, output_tail: output, output_truncated?: false}}
  end

  defp config do
    %{
      "__schema" => "v0.2",
      "project" => "fixture",
      "targets" => %{
        "production" => %{
          "image" => "fixtureImage",
          "ip" => "127.0.0.1",
          "port" => 22,
          "user" => "nixploy",
          "run" => %{"preStart" => [["/app/migrate"]]},
          "secrets" => %{"app" => "/nix/store/encrypted.env"},
          "web" => %{
            "domain" => "fixture.example.test",
            "healthPath" => "/ready",
            "slots" => %{"blue" => 8080, "green" => 8081}
          }
        }
      }
    }
  end
end
