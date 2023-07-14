# copied from Mint.TransportError
# https://github.com/elixir-mint/mint/blob/main/lib/mint/transport_error.ex
defmodule Mua.TransportError do
  @moduledoc """
  Represents an error with the transport used by an SMTP connection.

  Contains the following fields:

    - `:reason` - a term representing the error reason. The value of this field
      can be:

        - `:timeout` - if there's a timeout in interacting with the socket.

        - `:closed` - if the connection has been closed.

        - `t::inet.posix/0` - if there's any other error with the socket,
          such as `:econnrefused` or `:nxdomain`.

        - `t::ssl.error_alert/0` - if there's an SSL error.

  """

  @type t :: %__MODULE__{reason: :timeout | :closed | :inet.posix() | :ssl.error_alert()}
  defexception [:reason]

  def message(%__MODULE__{reason: reason}) do
    format_reason(reason)
  end

  defp format_reason(:closed), do: "socket closed"
  defp format_reason(:timeout), do: "timeout"

  # :ssl.format_error/1 falls back to :inet.format_error/1 when the error is not an SSL-specific
  # error (at least since OTP 19+), so we can just use that.
  defp format_reason(reason) do
    case :ssl.format_error(reason) do
      ~c"Unexpected error:" ++ _ -> inspect(reason)
      message -> List.to_string(message)
    end
  end
end
