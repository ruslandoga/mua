defmodule MuaTest do
  use ExUnit.Case, async: true

  describe "easy_send" do
    @describetag :mailhog

    setup do
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

      {:ok, message: message}
    end

    test "one recipient", %{message: message} do
      assert {:ok, _receipt} =
               Mua.easy_send(
                 "localhost",
                 "hey@copycat.fun",
                 ["dogaruslan@gmail.com"],
                 message,
                 port: 1025,
                 timeout: :timer.seconds(1)
               )
    end

    test "multiple recipients", %{message: message} do
      assert {:ok, _receipt} =
               Mua.easy_send(
                 "localhost",
                 "hey@copycat.fun",
                 ["dogaruslan@gmail.com", _bcc = "ruslandoga@gmail.com"],
                 message,
                 port: 1025,
                 timeout: :timer.seconds(1)
               )
    end

    test "auth", %{message: message} do
      assert {:ok, _receipt} =
               Mua.easy_send(
                 "localhost",
                 "hey@copycat.fun",
                 ["dogaruslan@gmail.com", _bcc = "ruslandoga@gmail.com"],
                 message,
                 port: 1025,
                 timeout: :timer.seconds(1),
                 username: "ruslandoga",
                 password: "swortfish"
               )
    end
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

    test "localhost (when mx record is not set)" do
      assert Mua.mxlookup("localhost") == []
    end
  end

  describe "connect/close" do
    @describetag :online

    test "tcp" do
      assert {:ok, socket, _banner} = Mua.connect(:tcp, "smtp.google.com", 25)
      assert :ok = Mua.close(socket)
    end

    test "ssl" do
      assert {:ok, socket, _banner} = Mua.connect(:ssl, "smtp.gmail.com", 465)
      assert :ok = Mua.close(socket)
    end
  end

  describe "ehlo/helo" do
    @describetag :online

    setup do
      assert {:ok, socket, _banner} = Mua.connect(:tcp, "smtp.gmail.com", 25)
      on_exit(fn -> :ok = Mua.close(socket) end)
      {:ok, socket: socket}
    end

    test "ehlo", %{socket: socket} do
      assert {:ok, extensions} = Mua.ehlo(socket, fqdn_or_localhost())
      assert "STARTTLS" in extensions
    end

    test "helo", %{socket: socket} do
      assert :ok = Mua.helo(socket, fqdn_or_localhost())
    end
  end

  describe "starttls" do
    @describetag :online

    setup do
      assert {:ok, socket, _banner} = Mua.connect(:tcp, "smtp.gmail.com", 25)
      on_exit(fn -> :ok = Mua.close(socket) end)

      assert {:ok, extensions} = Mua.ehlo(socket, fqdn_or_localhost())
      assert "STARTTLS" in extensions

      {:ok, socket: socket}
    end

    test "from tcp/25", %{socket: socket} do
      assert {:ok, socket} = Mua.starttls(socket, "smtp.gmail.com")
      assert {:ok, _cert} = :ssl.peercert(socket)
    end
  end

  describe "pick_auth_method/1" do
    test "no AUTH extension" do
      extensions = [
        "SIZE 35882577",
        "8BITMIME",
        "STARTTLS",
        "ENHANCEDSTATUSCODES",
        "PIPELINING",
        "CHUNKING",
        "SMTPUTF8"
      ]

      assert Mua.pick_auth_method(extensions) == nil
    end

    test "no supported AUTH method" do
      extensions = [
        "SIZE 35882577",
        "8BITMIME",
        "AUTH XOAUTH2 PLAIN-CLIENTTOKEN OAUTHBEARER XOAUTH",
        "ENHANCEDSTATUSCODES",
        "PIPELINING",
        "CHUNKING",
        "SMTPUTF8"
      ]

      assert Mua.pick_auth_method(extensions) == nil
    end

    test "PLAIN" do
      extensions = [
        "SIZE 35882577",
        "8BITMIME",
        "AUTH PLAIN LOGIN XOAUTH2 PLAIN-CLIENTTOKEN OAUTHBEARER XOAUTH",
        "ENHANCEDSTATUSCODES",
        "PIPELINING",
        "CHUNKING",
        "SMTPUTF8"
      ]

      assert Mua.pick_auth_method(extensions) == :plain
    end

    test "LOGIN" do
      extensions = [
        "SIZE 35882577",
        "8BITMIME",
        "AUTH LOGIN PLAIN XOAUTH2 PLAIN-CLIENTTOKEN OAUTHBEARER XOAUTH",
        "ENHANCEDSTATUSCODES",
        "PIPELINING",
        "CHUNKING",
        "SMTPUTF8"
      ]

      assert Mua.pick_auth_method(extensions) == :login
    end
  end

  defp fqdn_or_localhost do
    case Mua.guess_fqdn() do
      {:ok, fqdn} -> fqdn
      {:error, _reason} -> "localhost"
    end
  end
end
