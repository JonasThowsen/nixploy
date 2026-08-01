defmodule NixployWeb.ReleaseRegistrationController do
  use NixployWeb, :controller

  alias Nixploy.ReleaseRegistration

  @content_type "application/x-nix-export"
  @max_export_bytes 32 * 1_024 * 1_024
  @read_length 1_024 * 1_024
  @read_timeout :timer.seconds(30)

  def create(conn, _params) do
    with :ok <- validate_content_type(conn),
         :ok <- validate_content_length(conn),
         {:ok, export, conn} <- read_export(conn),
         attrs <- registration_headers(conn),
         {:ok, input, disposition} <-
           ReleaseRegistration.register(
             attrs,
             export,
             conn.assigns.release_registration_operator,
             conn.assigns.release_registration_config,
             request_id:
               List.first(get_resp_header(conn, "x-request-id")) || conn.assigns[:request_id]
           ) do
      status = if disposition == :created, do: :created, else: :ok

      conn
      |> put_status(status)
      |> json(%{
        data: %{
          id: input.id,
          state: input.state,
          project: input.derived_snapshot["project"],
          target: input.selected_target,
          nar_hash: input.nar_hash,
          configuration_digest: input.configuration_digest,
          source_repository: input.source_repository,
          source_revision: input.source_revision,
          release_url: url(~p"/releases/#{input.id}"),
          disposition: disposition,
          deployment_requested: false
        }
      })
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp validate_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [content_type] ->
        if content_type |> String.split(";", parts: 2) |> hd() |> String.trim() == @content_type,
          do: :ok,
          else: {:error, :invalid_content_type}

      _content_type ->
        {:error, :invalid_content_type}
    end
  end

  defp validate_content_length(conn) do
    case get_req_header(conn, "content-length") do
      [] ->
        :ok

      [value] ->
        case Integer.parse(value) do
          {length, ""} when length <= @max_export_bytes -> :ok
          _length -> {:error, :export_too_large}
        end

      _values ->
        {:error, :export_too_large}
    end
  end

  defp read_export(conn), do: read_export(conn, [], 0)

  defp read_export(conn, chunks, size) do
    opts = [
      length: @max_export_bytes + 1,
      read_length: @read_length,
      read_timeout: @read_timeout
    ]

    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} -> finish_export(conn, [chunk | chunks], size + byte_size(chunk))
      {:more, chunk, conn} -> continue_export(conn, [chunk | chunks], size + byte_size(chunk))
      {:error, _reason} -> {:error, :invalid_request}
    end
  end

  defp continue_export(_conn, _chunks, size)
       when size > @max_export_bytes,
       do: {:error, :export_too_large}

  defp continue_export(conn, chunks, size), do: read_export(conn, chunks, size)

  defp finish_export(_conn, _chunks, size) when size > @max_export_bytes,
    do: {:error, :export_too_large}

  defp finish_export(conn, chunks, _size),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), conn}

  defp registration_headers(conn) do
    %{
      store_path: header(conn, "x-nixploy-store-path"),
      nar_hash: header(conn, "x-nixploy-nar-hash"),
      project: header(conn, "x-nixploy-project"),
      target: header(conn, "x-nixploy-target"),
      repository: header(conn, "x-nixploy-repository"),
      revision: header(conn, "x-nixploy-revision")
    }
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _values -> nil
    end
  end

  defp render_error(conn, reason) do
    status =
      case reason do
        :export_too_large -> 413
        {:import_command_failed, _detail} -> :service_unavailable
        :import_timeout -> :gateway_timeout
        _reason -> :unprocessable_entity
      end

    conn
    |> put_status(status)
    |> json(%{
      error: %{code: error_code(reason), message: ReleaseRegistration.error_message(reason)}
    })
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp error_code(%{failure: %{"code" => code}}), do: code
  defp error_code(_reason), do: "registration_failed"
end
