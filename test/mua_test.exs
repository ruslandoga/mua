defmodule MuaTest do
  use ExUnit.Case

  test "it works" do
    now = DateTime.utc_now()

    message = """
    Date: #{Calendar.strftime(now, "%a, %d %b %Y %H:%M:%S %z")}\r
    From: Ruslan <hey@copycat.fun>\r
    Subject: Hey!\r
    To: Ruslan <dogaruslan@gmail.com>\r
    \r
    How was your day? Long time no see!\r
    .\r
    """

    assert {:ok, _receipt} =
             Mua.send(
               _host = "gmail.com",
               _from = "hey@copycat.fun",
               _recipients = ["dogaruslan@gmail.com"],
               message
             )
  end

  # @doc false
  # def wrap(email, now \\ DateTime.utc_now()) do
  #   date = Calendar.strftime(now, "%a, %d %b %Y %H:%M:%S %z")

  #   headers = [
  #     {"Date", date},
  #     {"From", email.sender},
  #     {"To", Enum.intersperse(email.recipients, ", ")},
  #     {"Subject", email.subject}
  #   ]

  #   headers = :lists.ukeysort(1, email.headers ++ headers)
  #   headers = for {k, v} <- headers, do: [k, ": ", v, "\r\n"]

  #   {
  #     email.sender,
  #     email.recipients,
  #     [headers, "\r\n" | email.message]
  #   }
  # end
end
