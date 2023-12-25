defmodule Mua.OnlineTest do
  use ExUnit.Case, async: true

  @moduletag :online

  # uses public network to test mx lookups and connections

  describe "mxlookup" do
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
    test "tcp" do
      assert {:ok, socket, _banner} = Mua.connect(:tcp, "smtp.google.com", 25)
      assert :ok = Mua.close(socket)
    end

    test "ssl" do
      assert {:ok, socket, _banner} = Mua.connect(:ssl, "smtp.gmail.com", 465)
      assert :ok = Mua.close(socket)

      assert {:ok, socket, _banner} =
               Mua.connect(:ssl, "smtp.gmail.com", 465,
                 versions: [:"tlsv1.3"],
                 verify: :verify_none
               )

      on_exit(fn -> :ok = Mua.close(socket) end)

      assert {:ok, [protocol: :"tlsv1.3", verify: :verify_none]} =
               :ssl.connection_information(socket, [:protocol, :verify])
    end

    test "ssl with cached cacertfile" do
      prev_env = Application.get_all_env(:mua)
      Application.put_env(:mua, :persistent_term, true)

      on_exit(fn ->
        case Keyword.fetch(prev_env, :persistent_term) do
          {:ok, prev} -> Application.put_env(:mua, :persistent_term, prev)
          :error -> Application.delete_env(:mua, :persistent_term)
        end
      end)

      assert {:ok, s1, _banner} = Mua.connect(:ssl, "smtp.gmail.com", 465)
      on_exit(fn -> Mua.close(s1) end)
      assert {:ok, s2, _banner} = Mua.connect(:ssl, "smtp.gmail.com", 465)
      on_exit(fn -> Mua.close(s2) end)
    end

    test "ssl with os cacerts" do
      assert :ok = :public_key.cacerts_load()
      assert [_ | _] = cacerts = :public_key.cacerts_get()
      assert {:ok, socket, _banner} = Mua.connect(:ssl, "smtp.gmail.com", 465, cacerts: cacerts)
      Mua.close(socket)
    end
  end

  describe "ehlo/helo" do
    setup do
      assert {:ok, socket, _banner} = Mua.connect(:tcp, "smtp.gmail.com", 25)
      on_exit(fn -> :ok = Mua.close(socket) end)
      {:ok, socket: socket}
    end

    test "ehlo", %{socket: socket} do
      assert {:ok, extensions} = Mua.ehlo(socket, _own_hostname = "localhost")
      assert "STARTTLS" in extensions
    end

    test "helo", %{socket: socket} do
      assert :ok = Mua.helo(socket, _own_hostname = "localhost")
    end
  end

  describe "starttls" do
    setup do
      assert {:ok, socket, _banner} = Mua.connect(:tcp, "smtp.gmail.com", 25)
      on_exit(fn -> :ok = Mua.close(socket) end)

      assert {:ok, extensions} = Mua.ehlo(socket, _own_hostname = "localhost")
      assert "STARTTLS" in extensions

      {:ok, socket: socket}
    end

    test "from tcp/25", %{socket: socket} do
      assert {:ok, socket} = Mua.starttls(socket, "smtp.gmail.com")
      assert {:ok, _cert} = :ssl.peercert(socket)
    end
  end

  describe "easy_send" do
    defp find_connected_socket do
      Enum.find(Port.list(), fn port ->
        Port.info(port)[:connected] == self()
      end)
    end

    defp find_open_socket(port) do
      Enum.find(Port.list(), fn p ->
        case :inet.peername(p) do
          {:ok, {_ip, ^port} = port} -> port
          _ -> false
        end
      end)
    end

    test "connected port checker" do
      assert {:ok, socket, _banner} = Mua.connect(:tcp, "smtp.gmail.com", 25)
      assert find_connected_socket() == socket
      Mua.close(socket)
      refute find_connected_socket()

      assert {:ok, socket, _banner} = Mua.connect(:ssl, "smtp.gmail.com", 465)
      assert find_open_socket(465)
      Mua.close(socket)
      refute find_open_socket(465)
    end

    test "closes tcp socket on error" do
      assert {:error, %Mua.SMTPError{code: 530} = error} =
               Mua.easy_send(
                 "smtp.gmail.com",
                 "mua@github.com",
                 ["support@gmail.com"],
                 "this is an invalid test message from https://github.com/ruslandoga/mua"
               )

      refute find_connected_socket()

      assert Exception.message(error) =~
               """
               530-5.7.0 Authentication Required. For more information, go to\r
               530 5.7.0  https://support.google.com/mail/?p=WantAuthError\
               """
    end

    test "closes ssl socket on error" do
      assert {:error, %Mua.SMTPError{code: 530} = error} =
               Mua.easy_send(
                 "smtp.gmail.com",
                 "mua@github.com",
                 ["support@gmail.com"],
                 "this is an invalid test message from https://github.com/ruslandoga/mua",
                 protocol: :ssl,
                 port: 465
               )

      refute find_open_socket(465)

      assert Exception.message(error) =~
               """
               530-5.7.0 Authentication Required. For more information, go to\r
               530 5.7.0  https://support.google.com/mail/?p=WantAuthError\
               """
    end

    test "fails on invalid auth with proper error message" do
      assert {:error, %Mua.SMTPError{code: 501} = error} =
               Mua.easy_send(
                 "smtp.mailgun.org",
                 "mua@github.com",
                 ["support@mailgun.org"],
                 "this is an invalid test message from https://github.com/ruslandoga/mua",
                 port: 587,
                 auth: [username: "username", password: "password"]
               )

      assert Exception.message(error) ==
               "501 Username used for auth is not valid email address\r\n"
    end
  end
end
