defmodule Mua.SMTPError do
  @moduledoc """
  An SMTP error.

  Contains the following fields:

    - `:code` - [SMTP error code](https://en.wikipedia.org/wiki/List_of_SMTP_server_return_codes)
    - `:lines` - lines received from the server

  """

  @type t :: %__MODULE__{code: pos_integer, lines: [String.t()]}
  defexception [:code, :lines]

  def message(%__MODULE__{lines: lines}) do
    IO.iodata_to_binary(lines)
  end
end
