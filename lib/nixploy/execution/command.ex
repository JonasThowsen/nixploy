defmodule Nixploy.Execution.Command do
  @moduledoc "A typed external command invocation without shell interpolation."

  @enforce_keys [:executable]
  defstruct executable: nil,
            args: [],
            cd: nil,
            env: %{},
            timeout: :timer.minutes(30),
            redact: [],
            max_output_bytes: 65_536

  @type t :: %__MODULE__{
          executable: String.t(),
          args: [String.t()],
          cd: String.t() | nil,
          env: %{optional(String.t()) => String.t() | false},
          timeout: non_neg_integer() | :infinity,
          redact: [String.t()],
          max_output_bytes: pos_integer()
        }
end
