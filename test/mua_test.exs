defmodule MuaTest do
  use ExUnit.Case, async: true

  alias Mua.Test.SMTPServer

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

    test "extension and mechanism names are case-insensitive" do
      assert Mua.pick_auth_method(["auth plain login"]) == :plain
      assert Mua.pick_auth_method(["AuTh LoGiN PLAIN"]) == :login
    end
  end

  describe "easy_send/5 TLS and authentication policy" do
    test "keeps unauthenticated delivery plaintext when STARTTLS is unavailable" do
      script =
        [
          {:send, "220 localhost ESMTP\r\n"},
          {:expect, "EHLO example.com\r\n"},
          {:send, "250-localhost\r\n250 SIZE 1000\r\n"}
        ] ++ successful_delivery_steps()

      assert {{:ok, "250 Accepted\r\n"}, transcript} = run_easy_send(script, auth: nil)

      assert transcript ==
               [{:tcp, "EHLO example.com\r\n"}] ++ successful_delivery_transcript(:tcp)
    end

    test "upgrades unauthenticated delivery when STARTTLS is available" do
      script =
        [
          {:send, "220 localhost ESMTP\r\n"},
          {:expect, "EHLO example.com\r\n"},
          {:send, "250-localhost\r\n250 starttls\r\n"},
          {:expect, "STARTTLS\r\n"},
          {:send, "220 Ready to start TLS\r\n"},
          :starttls,
          {:expect, "EHLO example.com\r\n"},
          {:send, "250-localhost\r\n250 SIZE 1000\r\n"}
        ] ++ successful_delivery_steps()

      assert {{:ok, "250 Accepted\r\n"}, transcript} = run_easy_send(script, auth: nil)

      assert transcript ==
               [
                 {:tcp, "EHLO example.com\r\n"},
                 {:tcp, "STARTTLS\r\n"},
                 {:ssl, "EHLO example.com\r\n"}
               ] ++ successful_delivery_transcript(:ssl)
    end

    test "requires STARTTLS by default when credentials are configured" do
      script = [
        {:send, "220 localhost ESMTP\r\n"},
        {:expect, "EHLO example.com\r\n"},
        {:send, "250-localhost\r\n250 AUTH PLAIN\r\n"},
        :expect_close
      ]

      assert {{:error, %Mua.ProtocolError{reason: :starttls_required}}, transcript} =
               run_easy_send(script)

      assert transcript == [{:tcp, "EHLO example.com\r\n"}]
    end

    test "honors an explicit STARTTLS requirement without authentication" do
      script = [
        {:send, "220 localhost ESMTP\r\n"},
        {:expect, "EHLO example.com\r\n"},
        {:send, "250-localhost\r\n250 SIZE 1000\r\n"},
        :expect_close
      ]

      assert {{:error, %Mua.ProtocolError{reason: :starttls_required}}, transcript} =
               run_easy_send(script, auth: nil, tls: :always)

      assert transcript == [{:tcp, "EHLO example.com\r\n"}]
    end

    test "does not downgrade when STARTTLS is rejected" do
      script = [
        {:send, "220 localhost ESMTP\r\n"},
        {:expect, "EHLO example.com\r\n"},
        {:send, "250-localhost\r\n250-starttls\r\n250 auth plain\r\n"},
        {:expect, "STARTTLS\r\n"},
        {:send, "454 TLS temporarily unavailable\r\n"},
        :expect_close
      ]

      assert {{:error, %Mua.SMTPError{code: 454}}, transcript} = run_easy_send(script)

      assert transcript == [
               {:tcp, "EHLO example.com\r\n"},
               {:tcp, "STARTTLS\r\n"}
             ]
    end

    test "uses lowercase STARTTLS and only post-TLS AUTH capabilities" do
      script = [
        {:send, "220 localhost ESMTP\r\n"},
        {:expect, "EHLO example.com\r\n"},
        {:send, "250-localhost\r\n250 starttls\r\n"},
        {:expect, "STARTTLS\r\n"},
        {:send, "220 Ready to start TLS\r\n"},
        :starttls,
        {:expect, "EHLO example.com\r\n"},
        {:send, "250-localhost\r\n250 SIZE 1000\r\n"},
        :expect_close
      ]

      assert {{:error, %Mua.ProtocolError{reason: :auth_not_supported}}, transcript} =
               run_easy_send(script)

      assert transcript == [
               {:tcp, "EHLO example.com\r\n"},
               {:tcp, "STARTTLS\r\n"},
               {:ssl, "EHLO example.com\r\n"}
             ]
    end

    test "authenticates only after TLS with case-insensitive extensions" do
      script =
        [
          {:send, "220 localhost ESMTP\r\n"},
          {:expect, "EHLO example.com\r\n"},
          {:send, "250-localhost\r\n250 starttls\r\n"},
          {:expect, "STARTTLS\r\n"},
          {:send, "220 Ready to start TLS\r\n"},
          :starttls,
          {:expect, "EHLO example.com\r\n"},
          {:send, "250-localhost\r\n250 aUtH pLaIn LoGiN\r\n"},
          {:expect, "AUTH PLAIN AGFsaWNlAHNlY3JldA==\r\n"},
          {:send, "235 Authentication successful\r\n"}
        ] ++ successful_delivery_steps()

      assert {{:ok, "250 Accepted\r\n"}, transcript} = run_easy_send(script)

      assert transcript ==
               [
                 {:tcp, "EHLO example.com\r\n"},
                 {:tcp, "STARTTLS\r\n"},
                 {:ssl, "EHLO example.com\r\n"},
                 {:ssl, "AUTH PLAIN AGFsaWNlAHNlY3JldA==\r\n"}
               ] ++ successful_delivery_transcript(:ssl)
    end

    test "does not invent PLAIN when AUTH is not advertised" do
      script = [
        {:send, "220 localhost ESMTP\r\n"},
        {:expect, "EHLO example.com\r\n"},
        {:send, "250-localhost\r\n250 SIZE 1000\r\n"},
        :expect_close
      ]

      assert {{:error, %Mua.ProtocolError{reason: :auth_not_supported}}, transcript} =
               run_easy_send(script, tls: :if_available)

      assert transcript == [{:tcp, "EHLO example.com\r\n"}]
    end

    test "allows an explicit plaintext authentication opt-out" do
      script = [
        {:send, "220 localhost ESMTP\r\n"},
        {:expect, "EHLO example.com\r\n"},
        {:send, "250-localhost\r\n250-starttls\r\n250 auth plain\r\n"},
        {:expect, "AUTH PLAIN AGFsaWNlAHNlY3JldA==\r\n"},
        {:send, "535 Invalid credentials\r\n"},
        :expect_close
      ]

      assert {{:error, %Mua.SMTPError{code: 535}}, transcript} =
               run_easy_send(script, tls: :never)

      assert transcript == [
               {:tcp, "EHLO example.com\r\n"},
               {:tcp, "AUTH PLAIN AGFsaWNlAHNlY3JldA==\r\n"}
             ]
    end

    test "preserves explicitly opportunistic authentication" do
      script = [
        {:send, "220 localhost ESMTP\r\n"},
        {:expect, "EHLO example.com\r\n"},
        {:send, "250-localhost\r\n250 auth plain\r\n"},
        {:expect, "AUTH PLAIN AGFsaWNlAHNlY3JldA==\r\n"},
        {:send, "535 Invalid credentials\r\n"},
        :expect_close
      ]

      assert {{:error, %Mua.SMTPError{code: 535}}, transcript} =
               run_easy_send(script, tls: :if_available)

      assert transcript == [
               {:tcp, "EHLO example.com\r\n"},
               {:tcp, "AUTH PLAIN AGFsaWNlAHNlY3JldA==\r\n"}
             ]
    end

    test "implicit TLS satisfies the authenticated default" do
      script = [
        :starttls,
        {:send, "220 localhost ESMTP\r\n"},
        {:expect, "EHLO example.com\r\n"},
        {:send, "250-localhost\r\n250 auth plain\r\n"},
        {:expect, "AUTH PLAIN AGFsaWNlAHNlY3JldA==\r\n"},
        {:send, "535 Invalid credentials\r\n"},
        :expect_close
      ]

      assert {{:error, %Mua.SMTPError{code: 535}}, transcript} =
               run_easy_send(script, protocol: :ssl)

      assert transcript == [
               {:ssl, "EHLO example.com\r\n"},
               {:ssl, "AUTH PLAIN AGFsaWNlAHNlY3JldA==\r\n"}
             ]
    end

    test "rejects an invalid TLS policy before connecting" do
      assert_raise ArgumentError,
                   "expected :tls to be :always, :if_available, or :never, got: :sometimes",
                   fn ->
                     Mua.easy_send(
                       "localhost",
                       "alice@example.com",
                       ["bob@example.net"],
                       "message",
                       tls: :sometimes
                     )
                   end
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

  test "protocol_error message" do
    assert Exception.message(Mua.ProtocolError.exception(reason: :starttls_required)) ==
             "STARTTLS is required but was not advertised by the server"

    assert Exception.message(Mua.ProtocolError.exception(reason: :auth_not_supported)) ==
             "the server did not advertise a supported authentication mechanism"
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

  defp run_easy_send(script, opts \\ []) do
    {server, port} = SMTPServer.start(script)

    result =
      Mua.easy_send(
        "localhost",
        "alice@example.com",
        ["bob@example.net"],
        "message",
        Keyword.merge(
          [
            port: port,
            timeout: :timer.seconds(2),
            auth: [username: "alice", password: "secret"],
            ssl: [verify: :verify_none]
          ],
          opts
        )
      )

    {result, SMTPServer.await(server)}
  end

  defp successful_delivery_steps do
    [
      {:expect, "MAIL FROM: <alice@example.com>\r\n"},
      {:send, "250 Sender accepted\r\n"},
      {:expect, "RCPT TO: <bob@example.net>\r\n"},
      {:send, "250 Recipient accepted\r\n"},
      {:expect, "DATA\r\n"},
      {:send, "354 Send message\r\n"},
      {:expect, "message\r\n"},
      {:expect, ".\r\n"},
      {:send, "250 Accepted\r\n"},
      {:expect, "QUIT\r\n"},
      {:send, "221 Bye\r\n"},
      :expect_close
    ]
  end

  defp successful_delivery_transcript(transport) do
    [
      {transport, "MAIL FROM: <alice@example.com>\r\n"},
      {transport, "RCPT TO: <bob@example.net>\r\n"},
      {transport, "DATA\r\n"},
      {transport, "message\r\n"},
      {transport, ".\r\n"},
      {transport, "QUIT\r\n"}
    ]
  end
end
