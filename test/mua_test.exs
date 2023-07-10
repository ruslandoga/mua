defmodule MuaTest do
  use ExUnit.Case, async: true

  @tag :integration
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
             Mua.easy_send(
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
      assert {:ok, socket, banner} = Mua.connect(:tcp, "gmail-smtp-in.l.google.com", 25)
      assert {:ok, {_v4 = {_, _, _, _}, 25}} = :inet.peername(socket)
      on_exit(fn -> :ok = Mua.close(socket) end)

      # "220 mx.google.com ESMTP x24-20020a634a18000000b0055217e19aa9si6717938pga.9 - gsmtp\r\n"
      assert String.starts_with?(banner, "220 mx.google.com ESMTP ")
      assert String.ends_with?(banner, " - gsmtp\r\n")
    end

    test "gmail-smtp-in.l.google.com on ipv6 port 25"

    test "smtp.gmail.com on ipv4 port 465" do
      assert {:ok, socket, banner} = Mua.connect(:ssl, "smtp.gmail.com", 465)
      assert {:ok, {_v4 = {_, _, _, _}, 465}} = :ssl.peername(socket)
      on_exit(fn -> :ok = Mua.close(socket) end)

      # "220 smtp.gmail.com ESMTP c13-20020a170902d48d00b001ae2b94701fsm5933163plg.21 - gsmtp\r\n"
      assert String.starts_with?(banner, "220 smtp.gmail.com ESMTP ")
      assert String.ends_with?(banner, " - gsmtp\r\n")
    end

    test "home-mx.app.hey.com on ipv4 port 25" do
      assert {:ok, socket, banner} = Mua.connect(:tcp, "home-mx.app.hey.com", 25)
      on_exit(fn -> :ok = Mua.close(socket) end)
      assert banner == "220 home-mx.app.hey.com ESMTP Postfix (Ubuntu)\r\n"
    end

    test "mx.yandex.ru on ipv4 port 25" do
      assert {:ok, socket, banner} = Mua.connect(:tcp, "mx.yandex.ru", 25)
      on_exit(fn -> :ok = Mua.close(socket) end)
      assert is_binary(banner)
    end

    test "copycat.fun (with no smtp server running)" do
      assert {:error, :timeout} = Mua.connect(:tcp, "copycat.fun", 25, timeout: :timer.seconds(1))
    end

    test "localhost (with no smtp server running)" do
      assert {:error, :econnrefused} = Mua.connect(:tcp, "localhost", 25, timeout: 100)
    end
  end

  describe "close" do
    test "gmail-smtp-in.l.google.com on ipv4 port 25" do
      assert {:ok, socket, _banner} = Mua.connect(:tcp, "gmail-smtp-in.l.google.com", 25)
      assert :ok = Mua.close(socket)
    end

    test "smtp.gmail.com on ipv4 port 465" do
      assert {:ok, socket, _banner} = Mua.connect(:ssl, "smtp.gmail.com", 465)
      assert :ok = Mua.close(socket)
    end
  end

  describe "ehlo" do
    test "gmail-smtp-in.l.google.com" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "gmail-smtp-in.l.google.com", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)

      assert {:ok, extensions} = Mua.ehlo(conn, fqdn_or_localhost())
      assert "STARTTLS" in extensions
    end

    test "smtp.gmail.com" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "smtp.gmail.com", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)

      assert {:ok, extensions} = Mua.ehlo(conn, fqdn_or_localhost())
      assert "STARTTLS" in extensions
    end

    test "home-mx.app.hey.com" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "home-mx.app.hey.com", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)

      assert {:ok, extensions} = Mua.ehlo(conn, fqdn_or_localhost())
      assert "STARTTLS" in extensions
    end

    test "mx.yandex.ru" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "mx.yandex.ru", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)

      assert {:ok, extensions} = Mua.ehlo(conn, fqdn_or_localhost())
      assert "STARTTLS" in extensions
    end
  end

  describe "helo" do
    test "gmail-smtp-in.l.google.com" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "gmail-smtp-in.l.google.com", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)
      assert :ok = Mua.helo(conn, fqdn_or_localhost())
    end

    test "smtp.gmail.com" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "smtp.gmail.com", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)
      assert :ok = Mua.helo(conn, fqdn_or_localhost())
    end

    test "home-mx.app.hey.com" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "home-mx.app.hey.com", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)
      assert :ok = Mua.helo(conn, fqdn_or_localhost())
    end

    test "mx.yandex.ru" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "mx.yandex.ru", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)
      assert :ok = Mua.helo(conn, fqdn_or_localhost())
    end
  end

  describe "starttls" do
    test "before ehlo"

    test "gmail-smtp-in.l.google.com" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "gmail-smtp-in.l.google.com", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)

      assert {:ok, extensions} = Mua.ehlo(conn, fqdn_or_localhost())
      assert "STARTTLS" in extensions

      assert {:ok, conn} = Mua.starttls(conn, "gmail-smtp-in.l.google.com")
      assert {:ok, _cert} = :ssl.peercert(conn)

      on_exit(fn -> :ok = Mua.close(conn) end)
    end

    test "smtp.gmail.com" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "smtp.gmail.com", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)

      assert {:ok, extensions} = Mua.ehlo(conn, fqdn_or_localhost())
      assert "STARTTLS" in extensions

      assert {:ok, conn} = Mua.starttls(conn, "smtp.gmail.com")
      assert {:ok, _cert} = :ssl.peercert(conn)

      on_exit(fn -> :ok = Mua.close(conn) end)
    end

    test "home-mx.app.hey.com" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "home-mx.app.hey.com", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)

      assert {:ok, extensions} = Mua.ehlo(conn, fqdn_or_localhost())
      assert "STARTTLS" in extensions

      assert {:ok, conn} = Mua.starttls(conn, "home-mx.app.hey.com")
      assert {:ok, _cert} = :ssl.peercert(conn)

      on_exit(fn -> :ok = Mua.close(conn) end)
    end

    test "mx.yandex.ru" do
      assert {:ok, conn, _banner} = Mua.connect(:tcp, "mx.yandex.ru", 25)
      on_exit(fn -> :ok = Mua.close(conn) end)

      assert {:ok, extensions} = Mua.ehlo(conn, fqdn_or_localhost())
      assert "STARTTLS" in extensions

      assert {:ok, conn} = Mua.starttls(conn, "mx.yandex.ru")
      assert {:ok, _cert} = :ssl.peercert(conn)

      on_exit(fn -> :ok = Mua.close(conn) end)
    end
  end

  describe "mail_from" do
    test "before ehlo" do
      assert {:ok, socket, _banner} = Mua.connect(:tcp, "smtp.gmail.com", 25)
      on_exit(fn -> :ok = Mua.close(socket) end)

      assert {:error, %Mua.SMTPError{} = error} = Mua.mail_from(socket, "hey@copycat.fun")

      assert error.code == 503
      assert Exception.message(error) =~ "5.5.1 EHLO/HELO first."
    end

    test "gmail.com" do
      assert [host | _rest] = Mua.mxlookup("gmail.com")
      assert {:ok, socket, _banner} = Mua.connect(:tcp, host, 25)
      on_exit(fn -> :ok = Mua.close(socket) end)
      assert {:ok, _extensions} = Mua.ehlo(socket, fqdn_or_localhost())
      assert :ok = Mua.mail_from(socket, "hey@copycat.fun")
    end
  end

  describe "rcpt_to" do
    test "before mail_from" do
      assert [host | _rest] = Mua.mxlookup("gmail.com")
      assert {:ok, socket, _banner} = Mua.connect(:tcp, host, 25)
      on_exit(fn -> :ok = Mua.close(socket) end)
      assert {:ok, _extensions} = Mua.ehlo(socket, fqdn_or_localhost())

      assert {:error, %Mua.SMTPError{} = error} = Mua.rcpt_to(socket, "dogaruslan@gmail.com")

      assert error.code == 503
      assert Exception.message(error) =~ "503 5.5.1 bad sequence of commands"
    end

    test "gmail.com" do
      assert [host | _rest] = Mua.mxlookup("gmail.com")
      assert {:ok, socket, _banner} = Mua.connect(:tcp, host, 25)
      on_exit(fn -> :ok = Mua.close(socket) end)
      assert {:ok, _extensions} = Mua.ehlo(socket, fqdn_or_localhost())
      assert :ok = Mua.mail_from(socket, "hey@copycat.fun")
      assert :ok = Mua.rcpt_to(socket, "dogaruslan@gmail.com")
    end
  end

  defp fqdn_or_localhost do
    case Mua.guess_fqdn() do
      {:ok, fqdn} -> fqdn
      {:error, _reason} -> "localhost"
    end
  end
end
