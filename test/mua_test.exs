defmodule MuaTest do
  use ExUnit.Case, async: true

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

  describe "easy_send/5 option validation" do
    test "rejects malformed, unknown, and duplicate options" do
      assert_raise ArgumentError, "expected options to be a keyword list", fn ->
        easy_send(%{port: 25})
      end

      assert_raise ArgumentError, ~r/unknown keys \[:unknown\] in options/, fn ->
        easy_send(unknown: true)
      end

      assert_raise ArgumentError, "duplicate keys [:port] in options", fn ->
        easy_send(port: 25, port: 26)
      end
    end

    test "validates scalar option values" do
      invalid_options = [
        {[timeout: -1],
         "invalid :timeout option: expected a non-negative integer or :infinity, got: -1"},
        {[mx: :yes], "invalid :mx option: expected a boolean, got: :yes"},
        {[protocol: :udp], "invalid :protocol option: expected :tcp or :ssl, got: :udp"},
        {[port: 65_536], "invalid :port option: expected an integer from 0 to 65535, got: 65536"}
      ]

      for {opts, message} <- invalid_options do
        assert_raise ArgumentError, message, fn -> easy_send(opts) end
      end
    end

    test "validates transport option lists" do
      assert_raise ArgumentError, "invalid :tcp option: expected a keyword list", fn ->
        easy_send(tcp: :inet6)
      end

      assert_raise ArgumentError, "invalid :ssl option: expected a keyword list", fn ->
        easy_send(ssl: {:verify, :verify_none})
      end
    end

    test "validates authentication options" do
      invalid_options = [
        {[auth: :invalid],
         "invalid :auth option: expected a keyword list with :username and :password"},
        {[auth: []], "missing :username in :auth option"},
        {[auth: [username: "user"]], "missing :password in :auth option"},
        {[auth: [username: :user, password: "secret"]],
         "invalid :username in :auth option: expected a string"},
        {[auth: [username: "user", password: :secret]],
         "invalid :password in :auth option: expected a string"}
      ]

      for {opts, message} <- invalid_options do
        assert_raise ArgumentError, message, fn -> easy_send(opts) end
      end

      assert_raise ArgumentError, ~r/unknown keys \[:token\] in :auth option/, fn ->
        easy_send(auth: [username: "user", password: "secret", token: "secret"])
      end

      assert_raise ArgumentError, "duplicate keys [:username] in :auth option", fn ->
        easy_send(auth: [username: "user", username: "another", password: "secret"])
      end
    end

    test "does not expose credentials in option errors" do
      error =
        assert_raise ArgumentError, fn ->
          easy_send(auth: [username: "user", password: "not-for-logs"], unknown: true)
        end

      refute Exception.message(error) =~ "not-for-logs"
    end

    test "requires a domain name when MX lookup is enabled" do
      assert_raise ArgumentError,
                   "the host must be a domain name when the :mx option is enabled",
                   fn -> easy_send([mx: true], {127, 0, 0, 1}) end
    end
  end

  test "transport_error message" do
    assert Exception.message(Mua.TransportError.exception(reason: :timeout)) == "timeout"
    assert Exception.message(Mua.TransportError.exception(reason: :closed)) == "socket closed"

    assert Exception.message(Mua.TransportError.exception(reason: :nxdomain)) ==
             "non-existing domain"

    assert Exception.message(Mua.TransportError.exception(reason: :econnrefused)) ==
             "connection refused"

    assert Exception.message(Mua.TransportError.exception(reason: :mua_sad)) ==
             ":mua_sad"
  end

  test "smtp_error message" do
    assert Exception.message(Mua.SMTPError.exception(code: 123, lines: ["a\n", "b"])) == "a\nb"
  end

  if System.otp_release() >= "25" do
    test "default ssl opts post v25" do
      assert [
               {:ciphers, _},
               {:customize_hostname_check, [match_fun: match_fun]},
               {:partial_chain, partial_chain},
               {:cacerts, cacerts},
               {:server_name_indication, ~c"smtp.gmail.com"},
               {:versions, [:"tlsv1.3", :"tlsv1.2"]},
               {:verify, :verify_peer},
               {:depth, 4},
               {:secure_renegotiate, true},
               {:reuse_sessions, true}
             ] = Mua.SSL.opts("smtp.gmail.com")

      assert String.ends_with?(
               inspect(match_fun),
               ":public_key.pkix_verify_hostname_match_fun/1>"
             )

      assert String.ends_with?(inspect(partial_chain), "Mua.SSL.add_partial_chain_fun/1>")

      refute Enum.empty?(cacerts)
      assert cacerts == :public_key.cacerts_get()
    end
  end

  if System.otp_release() < "25" do
    test "default ssl opts pre v25" do
      assert [
               {:ciphers, _},
               {:customize_hostname_check, [match_fun: match_fun]},
               {:partial_chain, partial_chain},
               {:cacertfile, cacertfile},
               {:server_name_indication, ~c"smtp.gmail.com"},
               {:versions, [:"tlsv1.3", :"tlsv1.2"]},
               {:verify, :verify_peer},
               {:depth, 4},
               {:secure_renegotiate, true},
               {:reuse_sessions, true}
             ] = Mua.SSL.opts("smtp.gmail.com")

      assert String.ends_with?(
               inspect(match_fun),
               ":public_key.pkix_verify_hostname_match_fun/1>"
             )

      assert String.ends_with?(inspect(partial_chain), "Mua.SSL.add_partial_chain_fun/1>")
      assert String.ends_with?(cacertfile, "/lib/castore/priv/cacerts.pem")
    end
  end

  test "ssl opts when host is ip addr" do
    assert_raise ArgumentError,
                 "the :hostname option is required when address is not a binary",
                 fn -> Mua.SSL.opts({127, 0, 0, 1}) end

    opts = Mua.SSL.opts({127, 0, 0, 1}, hostname: "smtp.gmail.com")
    assert Keyword.fetch!(opts, :server_name_indication) == ~c"smtp.gmail.com"
  end

  defp easy_send(opts, host \\ "example.invalid") do
    apply(Mua, :easy_send, [
      host,
      "sender@example.com",
      ["recipient@example.com"],
      "Subject: test\r\n\r\ntest",
      opts
    ])
  end
end
