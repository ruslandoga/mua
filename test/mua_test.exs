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
end
