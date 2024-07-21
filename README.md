# Mua

[![Documentation badge](https://img.shields.io/badge/Documentation-ff69b4)](https://hexdocs.pm/mua)
[![Hex.pm badge](https://img.shields.io/badge/Package%20on%20hex.pm-informational)](https://hex.pm/packages/mua)

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
    port: 1025,
    auth: [username: "username", password: "password"]
  )
```

Low-level API:

```elixir
{:ok, socket, _banner} = Mua.connect(:tcp, "localhost", _port = 1025)
{:ok, extensions} = Mua.ehlo(socket, _sending_domain = "github.com")

{:ok, socket} =
  if "STARTTLS" in extensions do
    Mua.starttls(socket, "localhost")
  else
    {:ok, socket}
  end

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
