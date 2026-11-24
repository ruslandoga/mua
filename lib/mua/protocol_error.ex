defmodule Mua.ProtocolError do
  @moduledoc """
  Represents an error returned when a server cannot satisfy an SMTP protocol policy.

  Contains the following field:

    - `:reason` - the protocol policy that could not be satisfied.

  """

  @type reason :: :starttls_required | :auth_not_supported
  @type t :: %__MODULE__{reason: reason}
  defexception [:reason]

  def message(%__MODULE__{reason: :starttls_required}) do
    "STARTTLS is required but was not advertised by the server"
  end

  def message(%__MODULE__{reason: :auth_not_supported}) do
    "the server did not advertise a supported authentication mechanism"
  end
end
