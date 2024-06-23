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
               {:ciphers, ciphers},
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

      expected_ciphers_count =
        if System.otp_release() == "23" do
          66
        else
          63
        end

      assert length(ciphers) == expected_ciphers_count
    end
  end

  if System.otp_release() < "25" do
    test "default ssl opts pre v25" do
      assert [
               {:ciphers, ciphers},
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

      expected_ciphers_count =
        if System.otp_release() == "23" do
          66
        else
          63
        end

      assert length(ciphers) == expected_ciphers_count
    end
  end

  test "ssl opts when host is ip addr" do
    assert_raise ArgumentError,
                 "the :hostname option is required when address is not a binary",
                 fn -> Mua.SSL.opts({127, 0, 0, 1}) end

    opts = Mua.SSL.opts({127, 0, 0, 1}, hostname: "smtp.gmail.com")
    assert Keyword.fetch!(opts, :server_name_indication) == ~c"smtp.gmail.com"
  end
end
