defmodule Bench do
  def prev_approach(message) do
    message = IO.iodata_to_binary(message)
    escape_leading_dot(message, 0, 0, message, [])
  end

  defp escape_leading_dot(<<?\n, ?., rest::bytes>>, from, len, original, acc) do
    acc = ["\n..", binary_part(original, from, len) | acc]
    escape_leading_dot(rest, from + len + 2, 0, original, acc)
  end

  defp escape_leading_dot(<<_, rest::bytes>>, from, len, original, acc) do
    escape_leading_dot(rest, from, len + 1, original, acc)
  end

  defp escape_leading_dot(<<>>, _from, _len, original, []) do
    original
  end

  defp escape_leading_dot(<<>>, from, len, original, acc) do
    escaped_parts = [binary_part(original, from, len) | acc]
    :lists.reverse(escaped_parts)
  end
end

Benchee.run(
  %{
    "current approach" => &Mua.do_dot_stuffing/1,
    "prev approach" => &Bench.prev_approach/1,
    "String.replace/3" => fn message -> String.replace(message, "\n.", "\n..") end
  },
  inputs: %{
    "small w/ dot" => """
    Message-ID: <1234567890@localhost>
    Date: Fri, 30 Sep 2016 12:02:00 +0200
    From: me@localhost
    To: you@localhost
    Subject: Test message

    This is a test message
    . with a dot
    in a line
    """,
    "small w/o dot" => """
    Message-ID: <1234567890@localhost>
    Date: Fri, 30 Sep 2016 12:02:00 +0200
    From: me@localhost
    To: you@localhost
    Subject: Test message

    This is a test message
    without a dot
    in a line
    """
  }
)
