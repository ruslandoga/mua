defmodule NaiveSMTPTest do
  use ExUnit.Case

  test "it works" do
    email = %{
      sender: "hey@copycat.fun",
      recipients: ["dogaruslan@gmail.com"],
      subject: "hey",
      headers: [],
      message: "hey"
    }

    assert [{:ok, _receipt}] = NaiveSMTP.send(email)
  end
end
