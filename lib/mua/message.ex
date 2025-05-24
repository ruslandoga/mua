defmodule Mua.Message do
  @moduledoc false

  # https://datatracker.ietf.org/doc/html/rfc2822
  # https://en.wikipedia.org/wiki/Email#Message_format

  def render(headers, [part]) do
    [render_headers(headers), "\r\n" | encode_quoted_printable(part)]
  end

  def render(headers, [_multi | _part] = parts) do
    boundary = "boundary"
    headers = [{"content-type", "multipart/mixed; boundary=#{boundary}"} | headers]
    [render_headers(headers), "\r\n" | render_parts(parts, boundary)]
  end

  defp render_headers([{k, v} | headers]) when is_binary(k) and is_binary(v) do
    [k, ": ", v, "\r\n" | render_headers(headers)]
  end

  defp render_headers([] = empty), do: empty

  defp render_parts([part | parts], boundary) do
    [encode_quoted_printable(part), "\r\n" | render_parts(parts, boundary)]
  end

  defp render_parts([] = empty, _boundary), do: empty

  # https://datatracker.ietf.org/doc/html/rfc2045
  # https://en.wikipedia.org/wiki/Quoted-printable

  @doc """
  Encodes a string into quoted-printable format.

      iex> encode_quoted_printable("Hello, world!")
      "Hello, world!"

      iex> encode_quoted_printable("façade")
      "fa=C3=A7ade"

  """
  def encode_quoted_printable(data, max_len \\ 76) do
    qp(data, _pos = 0, _skip = 0, _acc = [], _line_len = 0, max_len, data)
  end

  defp qp(<<>>, _pos, _skip = 0, acc, _line_len, _max_len, _data) do
    acc
  end

  # Encode ASCII characters in range 0x20..0x7E, except reserved symbols:
  # 0x3F (question mark), 0x3D (equal sign) and 0x5F (underscore)
  defp qp(<<c, rest::bytes>>, pos, len, acc, line_len, max_len, data)
       when c in ?!..?~ and c not in [?=, ??, ?_] do
    if line_len < max_len - 1 do
      qp(rest, pos, len + 1, acc, line_len + 1, max_len, data)
    else
      bin = :binary.part(data, pos, len)
      qp(rest, pos + len, 0, [acc, bin | "=\r\n"], 0, max_len, data)
    end
  end

  # Encode ASCII tab and space characters.
  defp qp(<<c, rest::bytes>>, pos, len, acc, line_len, max_len, data) when c in [?\t, ?\s] do
  end
end
