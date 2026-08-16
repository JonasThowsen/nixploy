defmodule Nixploy.Operations.StatusProbe do
  @moduledoc "Reads web-service runtime state from Podman, Caddy, and the public health endpoint."

  alias Nixploy.Execution
  alias Nixploy.Execution.Command

  @command_timeout :timer.seconds(30)
  @health_timeout_seconds 10
  @route_prefix "nixploy-route-"

  def observe(service, opts \\ []) do
    # TODO(tracer): Add strategy-specific probes after the web/blue-green path
    # proves the worker credential and persisted-observation boundary.
    # TODO(tracer): Replace whole-target JSON snapshots with scoped Podman and
    # Caddy API queries before large targets can exceed bounded command output.
    with :ok <- require_domain(service),
         {:ok, podman_output} <- ssh(service.target, "podman ps -a --format json", opts),
         {:ok, caddy_output} <-
           ssh(
             service.target,
             "curl --fail --silent --show-error http://127.0.0.1:2019/config/apps/http/servers/nixploy/routes",
             opts
           ),
         {:ok, containers} <- decode_list(podman_output, :podman),
         {:ok, routes} <- decode_list(caddy_output, :caddy),
         {:ok, observed} <- observed_runtime(service, containers, routes),
         {:ok, health} <- health(observed.health_url, opts) do
      {:ok, Map.merge(observed, health)}
    end
  end

  @doc false
  def observed_runtime(service, containers, routes) do
    with {:ok, route} <- route_for_domain(routes, service.domain),
         {:ok, route_id} <- fetch_binary(route, "@id", :caddy_route_id_missing),
         {:ok, target_identity} <- target_identity(route_id),
         {:ok, upstream} <- route_upstream(route),
         {:ok, active_container} <- active_container(containers, target_identity, upstream),
         {:ok, active_name} <- container_name(active_container),
         {:ok, active_slot} <- slot_from_name(active_name) do
      inactive_slot = opposite_slot(active_slot)
      inactive_name = "#{target_identity}-#{inactive_slot}"
      inactive_container = container_by_name(containers, inactive_name)
      labels = active_container["Labels"] || %{}

      {:ok,
       %{
         target_identity: target_identity,
         active_slot: active_slot,
         inactive_slot: inactive_slot,
         active_container: active_name,
         active_container_state: container_state(active_container),
         inactive_container: inactive_name,
         inactive_container_state: container_state(inactive_container),
         image: active_container["Image"],
         git_commit: labels["nixploy.git_commit"],
         deployed_at: parse_datetime(labels["nixploy.deployed_at"]),
         caddy_route: route_id,
         upstream: upstream,
         health_url: health_url(service)
       }}
    end
  end

  defp ssh(target, remote_command, opts) do
    # TODO(tracer): Resolve target credential references explicitly instead of
    # relying only on the worker process SSH agent.
    executable = Application.get_env(:nixploy, :ssh_executable, "ssh")

    command = %Command{
      executable: executable,
      args: [
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "ConnectTimeout=10",
        "-p",
        Integer.to_string(target.ssh_port),
        "--",
        "#{target.ssh_user}@#{target.host}",
        remote_command
      ],
      timeout: @command_timeout
    }

    run(command, :ssh, opts)
  end

  defp health(url, opts) do
    executable = Application.get_env(:nixploy, :curl_executable, "curl")

    command = %Command{
      executable: executable,
      args: [
        "--silent",
        "--show-error",
        "--output",
        "/dev/null",
        "--write-out",
        "%{http_code}",
        "--max-time",
        Integer.to_string(@health_timeout_seconds),
        "--",
        url
      ],
      timeout: :timer.seconds(@health_timeout_seconds + 5)
    }

    case run(command, :health, opts) do
      {:ok, status} ->
        health =
          case Integer.parse(String.trim(status)) do
            {status, ""} -> %{health_status: status, health_error: nil}
            _invalid -> %{health_status: nil, health_error: "invalid HTTP status response"}
          end

        {:ok, health}

      {:error, :cancelled} ->
        {:error, :cancelled}

      {:error, reason} ->
        {:ok, %{health_status: nil, health_error: format_error(reason)}}
    end
  end

  defp run(command, source, opts) do
    case Execution.run(command, opts) do
      {:ok, %{exit_status: 0, output_tail: output}} -> {:ok, output}
      {:ok, result} -> {:error, {source, :command_failed, result.exit_status, result.output_tail}}
      {:error, :cancelled} -> {:error, :cancelled}
      {:error, reason} -> {:error, {source, reason}}
    end
  end

  defp decode_list(output, source) do
    case Jason.decode(output) do
      {:ok, values} when is_list(values) -> {:ok, values}
      {:ok, _other} -> {:error, {source, :unexpected_json}}
      {:error, error} -> {:error, {source, :invalid_json, Exception.message(error)}}
    end
  end

  defp require_domain(%{domain: domain}) when is_binary(domain) and domain != "", do: :ok
  defp require_domain(_service), do: {:error, :web_service_domain_required}

  defp route_for_domain(routes, domain) do
    case Enum.find(routes, &route_matches_domain?(&1, domain)) do
      nil -> {:error, {:caddy_route_not_found, domain}}
      route -> {:ok, route}
    end
  end

  defp route_matches_domain?(route, domain) do
    route
    |> Map.get("match", [])
    |> Enum.any?(fn matcher -> domain in Map.get(matcher, "host", []) end)
  end

  defp target_identity(@route_prefix <> target_identity) when target_identity != "",
    do: {:ok, target_identity}

  defp target_identity(_route_id), do: {:error, :unrecognized_caddy_route}

  defp route_upstream(route) do
    case find_reverse_proxy(route) do
      %{"upstreams" => [%{"dial" => upstream} | _]} when is_binary(upstream) ->
        {:ok, upstream}

      _proxy ->
        {:error, :caddy_upstream_not_found}
    end
  end

  defp find_reverse_proxy(%{"handler" => "reverse_proxy"} = handler), do: handler

  defp find_reverse_proxy(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.find_value(&find_reverse_proxy/1)
  end

  defp find_reverse_proxy(value) when is_list(value),
    do: Enum.find_value(value, &find_reverse_proxy/1)

  defp find_reverse_proxy(_value), do: nil

  defp active_container(containers, target_identity, upstream) do
    candidates =
      Enum.filter(containers, fn container ->
        container["State"] == "running" and
          Enum.any?(container["Names"] || [], &String.starts_with?(&1, target_identity <> "-"))
      end)

    case candidates do
      [container] ->
        {:ok, container}

      [] ->
        {:error, {:active_container_not_found, target_identity}}

      multiple ->
        # TODO(tracer): Persist normalized slot-to-port configuration so active
        # selection does not rely on the legacy 8080/8081 convention.
        with {:ok, slot} <- conventional_slot(upstream),
             container when not is_nil(container) <-
               Enum.find(multiple, &container_has_slot?(&1, slot)) do
          {:ok, container}
        else
          _ambiguous -> {:error, {:active_container_ambiguous, target_identity}}
        end
    end
  end

  defp conventional_slot(upstream) do
    case upstream |> String.split(":") |> List.last() do
      "8080" -> {:ok, "blue"}
      "8081" -> {:ok, "green"}
      _port -> {:error, :unknown_slot_port}
    end
  end

  defp container_has_slot?(container, slot) do
    Enum.any?(container["Names"] || [], &String.ends_with?(&1, "-#{slot}"))
  end

  defp container_name(%{"Names" => [name | _]}) when is_binary(name), do: {:ok, name}
  defp container_name(_container), do: {:error, :container_name_missing}

  defp container_by_name(containers, name) do
    Enum.find(containers, fn container -> name in (container["Names"] || []) end)
  end

  defp container_state(nil), do: "absent"

  defp container_state(container) do
    [container["State"], container["Status"]]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" · ")
  end

  defp slot_from_name(name) do
    cond do
      String.ends_with?(name, "-blue") -> {:ok, "blue"}
      String.ends_with?(name, "-green") -> {:ok, "green"}
      true -> {:error, {:container_slot_missing, name}}
    end
  end

  defp opposite_slot("blue"), do: "green"
  defp opposite_slot("green"), do: "blue"

  defp health_url(service) do
    # TODO(tracer): Persist health scheme/host overrides before probing private
    # services or applications that don't use their public HTTPS domain.
    %URI{scheme: "https", host: service.domain, path: service.health_path}
    |> URI.to_string()
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp fetch_binary(map, key, error) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, error}
    end
  end

  defp format_error({source, :command_failed, status, output}) do
    "#{source} exited with status #{status}: #{String.trim(output)}"
  end

  defp format_error(reason), do: inspect(reason)
end
