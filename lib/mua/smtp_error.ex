defmodule Mua.SMTPError do
  @moduledoc """
  An SMTP error.

  Contains the following fields:

    - `:code` - [SMTP error code](https://en.wikipedia.org/wiki/List_of_SMTP_server_return_codes)
    - `:message` - extra text message added by the SMTP server

  """

  @type t :: %__MODULE__{code: pos_integer, message: String.t()}
  defexception [:code, :message]

  def message(%__MODULE__{code: code, message: message}) do
    "#{code} - #{message}"
  end
end
