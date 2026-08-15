defmodule Nixploy.Audit do
  @moduledoc "Append-only operator and worker action history."

  import Ecto.Query, warn: false

  alias Nixploy.Audit.Event
  alias Nixploy.Repo

  @login_window_seconds 300
  @login_failure_limit 10

  def list_recent_events(limit \\ 100) when limit in 1..500 do
    Event
    |> order_by([event], desc: event.occurred_at, desc: event.id)
    |> limit(^limit)
    |> preload(:operator)
    |> Repo.all()
  end

  def login_allowed?(email_fingerprint, origin) do
    since = DateTime.add(DateTime.utc_now(), -@login_window_seconds, :second)

    failures =
      Event
      |> where(
        [event],
        event.action == "login_failed" and event.occurred_at >= ^since and
          (fragment("?->>'email_fingerprint' = ?", event.metadata, ^email_fingerprint) or
             fragment("?->>'origin' = ?", event.metadata, ^origin))
      )
      |> Repo.aggregate(:count)

    failures < @login_failure_limit
  end

  def record(operator, action, resource_type, resource_id, opts \\ []) do
    attrs = attributes(operator, action, resource_type, resource_id, opts)

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  def changeset(operator, action, resource_type, resource_id, opts \\ []) do
    Event.changeset(%Event{}, attributes(operator, action, resource_type, resource_id, opts))
  end

  defp attributes(operator, action, resource_type, resource_id, opts) do
    %{
      operator_id: operator_id(operator),
      action: to_string(action),
      resource_type: to_string(resource_type),
      resource_id: to_string(resource_id),
      outcome: opts |> Keyword.get(:outcome, :succeeded) |> to_string(),
      metadata: Keyword.get(opts, :metadata, %{}),
      occurred_at: DateTime.utc_now()
    }
  end

  defp operator_id(%{id: id}), do: id
  defp operator_id(id) when is_binary(id), do: id
  defp operator_id(nil), do: nil
end
