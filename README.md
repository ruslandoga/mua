# Mua

[![Documentation badge](https://img.shields.io/badge/Documentation-ff69b4)](https://hexdocs.pm/mua)
[![Hex.pm badge](https://img.shields.io/badge/Package%20on%20hex.pm-informational)](https://hex.pm/packages/mua)
[![Coverage Status](https://coveralls.io/repos/github/ruslandoga/mua/badge.svg?branch=coveralls)](https://coveralls.io/github/ruslandoga/mua?branch=coveralls)

Minimal SMTP client (aka Mail user agent).

Can be used with [Bamboo](https://github.com/ruslandoga/bamboo_mua) and [Swoosh.](https://hexdocs.pm/swoosh/Swoosh.Adapters.Mua.html)

### Features

- Direct messaging (no relays)
- Indirect messaging (relays)
- Minimal API
- Processless

## Installation

```elixir
defp deps do
  [
    {:mua, "~> 0.2.0"}
  ]
end
```

## Usage

This demo will use [Mailpit:](https://github.com/axllent/mailpit)

```console
$ docker run -d --rm -p 1025:1025 -p 8025:8025 -e "MP_SMTP_AUTH_ACCEPT_ANY=1" -e "MP_SMTP_AUTH_ALLOW_INSECURE=1" --name mailpit axllent/mailpit
$ open http://localhost:8025
```

High-level API:

```elixir
message = """
Date: Mon, 25 Dec 2023 06:52:15 +0000\r
From: Mua <mua@github.com>\r
Subject: README\r
To: Mr Receiver <receiver1@mailpit.example>\r
CC: Ms Receiver <receiver2@mailpit.example>\r
\r
like and subscribe
"""

{:ok, _receipt} =
  Mua.easy_send(
    _host = "localhost",
    _mail_from = "mua@github.com",
    _rcpt_to = ["receiver1@mailpit.example", "receiver2@mailpit.example"],
    message,
    port: 1025
  )
```

Authenticated TCP connections require STARTTLS by default. The available TLS policies are:

- `tls: :always` requires STARTTLS. This is the default when `auth:` is configured.
- `tls: :if_available` upgrades when the server advertises STARTTLS. This is the default without authentication.
- `tls: :never` skips STARTTLS.

Both `:if_available` and `:never` can expose credentials on a plaintext TCP connection. Use them with authentication only when that risk is explicitly acceptable, such as an isolated local Mailpit instance:

```elixir
Mua.easy_send("localhost", "mua@github.com", ["mailpit@localhost"], message,
  port: 1025,
  tls: :never,
  auth: [username: "username", password: "password"]
)
```

`protocol: :ssl` uses implicit TLS and does not perform STARTTLS.

When STARTTLS is advertised but its command or TLS handshake fails, Mua returns the error and never downgrades to plaintext. A required but unadvertised STARTTLS capability returns `{:error, %Mua.TransportError{reason: :starttls_required}}`. Configured credentials without a supported, advertised AUTH mechanism return `{:error, %Mua.TransportError{reason: :auth_not_supported}}`.

Secure low-level API:

```elixir
{:ok, socket, _banner} = Mua.connect(:tcp, "smtp.example.com", _port = 587)
{:ok, extensions} = Mua.ehlo(socket, _sending_domain = "github.com")

true = Enum.any?(extensions, &(String.upcase(&1) == "STARTTLS"))
{:ok, socket} = Mua.starttls(socket, "smtp.example.com")

# STARTTLS discards the previous SMTP capability state.
{:ok, extensions} = Mua.ehlo(socket, _sending_domain = "github.com")

:plain = Mua.pick_auth_method(extensions)
:ok = Mua.auth(socket, :plain, username: "username", password: "password")

:ok = Mua.mail_from(socket, "mua@github.com")
:ok = Mua.rcpt_to(socket, "receiver@mailpit.example")

message =
  """
  Date: Mon, 25 Dec 2023 06:52:15 +0000\r
  From: Mua <mua@github.com>\r
  Subject: How was your day?\r
  To: Mr Receiver <receiver@mailpit.example>\r
  \r
  Mine was fine.
  """

{:ok, _receipt} = Mua.data(socket, message)
:ok = Mua.close(socket)
```
