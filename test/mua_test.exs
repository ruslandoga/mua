defmodule MuaTest do
  use ExUnit.Case, async: true

  @tag :online
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

  describe "mxlookup" do
    @tag :online
    test "gmail.com" do
      assert Mua.mxlookup("gmail.com") == [
               "gmail-smtp-in.l.google.com",
               "alt1.gmail-smtp-in.l.google.com",
               "alt2.gmail-smtp-in.l.google.com",
               "alt3.gmail-smtp-in.l.google.com",
               "alt4.gmail-smtp-in.l.google.com"
             ]
    end

    @tag :online
    test "hey.com" do
      assert Mua.mxlookup("hey.com") == ["home-mx.app.hey.com"]
    end

    @tag :online
    test "ya.ru" do
      assert Mua.mxlookup("ya.ru") == ["mx.yandex.ru"]
    end

    @tag :online
    test "copycat.fun (when mx record is not set)" do
      assert Mua.mxlookup("copycat.fun") == []
    end

    test "localhost (when mx record is not set)" do
      assert Mua.mxlookup("localhost") == []
    end
  end

  describe "connect" do
    @tag :online
    test "gmail-smtp-in.l.google.com on ipv4 port 25" do
      assert {:ok, conn, banner} = Mua.connect(:tcp, "gmail-smtp-in.l.google.com", 25)
      assert {:ok, {_v4 = {_, _, _, _}, 25}} = :inet.peername(conn)
      on_exit(fn -> :ok = Mua.close(conn) end)

      # "mx.google.com ESMTP x24-20020a634a18000000b0055217e19aa9si6717938pga.9 - gsmtp"
      assert String.starts_with?(banner, "mx.google.com ESMTP ")
      assert String.ends_with?(banner, " - gsmtp")
    end

    @tag :online
    test "gmail-smtp-in.l.google.com on ipv6 port 25"

    @tag :online
    test "smtp.gmail.com on ipv4 port 465" do
      assert {:ok, conn, banner} = Mua.connect(:ssl, "smtp.gmail.com", 465)
      assert {:ok, {_v4 = {_, _, _, _}, 465}} = :ssl.peername(conn)
      on_exit(fn -> :ok = Mua.close(conn) end)

      # "smtp.gmail.com ESMTP c13-20020a170902d48d00b001ae2b94701fsm5933163plg.21 - gsmtp"
      assert String.starts_with?(banner, "smtp.gmail.com ESMTP ")
      assert String.ends_with?(banner, " - gsmtp")
    end

    @tag :online
    test "home-mx.app.hey.com on ipv4 port 25" do
      assert {:ok, conn, banner} = Mua.connect(:tcp, "home-mx.app.hey.com", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)
      assert banner == "home-mx.app.hey.com ESMTP Postfix (Ubuntu)"
    end

    @tag :online
    test "mx.yandex.ru on ipv4 port 25" do
      assert {:ok, conn, banner} = Mua.connect(:tcp, "mx.yandex.ru", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)
      assert is_binary(banner)
    end

    @tag :online
    test "copycat.fun (with no smtp server running)" do
      assert {:error, :timeout} = Mua.connect(:tcp, "copycat.fun", 25, timeout: :timer.seconds(1))
    end

    test "localhost (with no smtp server running)" do
      assert {:error, :econnrefused} = Mua.connect(:tcp, "localhost", 25, timeout: 100)
    end
  end

  describe "ehlo" do
    test "gmail-smtp-in.l.google.com" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "gmail-smtp-in.l.google.com", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)

      assert {:ok, extensions} = Mua.ehlo(conn, _hostname = "mac3", _timeout = :timer.seconds(1))

      assert Enum.sort(extensions) == [
               {"SIZE", "157286400"},
               "8BITMIME",
               "CHUNKING",
               "ENHANCEDSTATUSCODES",
               "PIPELINING",
               "SMTPUTF8",
               "STARTTLS"
             ]
    end

    test "smtp.gmail.com" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "smtp.gmail.com", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)

      assert {:ok, extensions} = Mua.ehlo(conn, _hostname = "mac3", _timeout = :timer.seconds(1))

      assert Enum.sort(extensions) == [
               {"SIZE", "35882577"},
               "8BITMIME",
               "CHUNKING",
               "ENHANCEDSTATUSCODES",
               "PIPELINING",
               "SMTPUTF8",
               "STARTTLS"
             ]
    end

    test "home-mx.app.hey.com" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "home-mx.app.hey.com", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)

      assert {:ok, extensions} = Mua.ehlo(conn, _hostname = "mac3", _timeout = :timer.seconds(1))

      assert Enum.sort(extensions) == [
               {"SIZE", "39146841"},
               "8BITMIME",
               "CHUNKING",
               "ENHANCEDSTATUSCODES",
               "PIPELINING",
               "STARTTLS"
             ]
    end

    test "mx.yandex.ru" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "mx.yandex.ru", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)
      assert {:ok, extensions} = Mua.ehlo(conn, _hostname = "mac3", _timeout = :timer.seconds(1))

      assert Enum.sort(extensions) == [
               {"SIZE", "53477376"},
               "8BITMIME",
               "DSN",
               "ENHANCEDSTATUSCODES",
               "PIPELINING",
               "STARTTLS"
             ]
    end
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
