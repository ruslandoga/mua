# Mua

[![Hex Package](https://img.shields.io/hexpm/v/mua.svg)](https://hex.pm/packages/mua)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/mua)

Minimal SMTP client (aka Mail user agent).

Can be used with [Bamboo](https://github.com/ruslandoga/bamboo_mua) and [Swoosh.](https://hexdocs.pm/swoosh/Swoosh.Adapters.Mua.html)

### Features

- Direct messaging (no relays)
- Inderect messaging (relays)
- Minimal API
- Processless

## Installation

```elixir
defp deps do
  [
    {:mua, "~> 0.1.0"}
  ]
end
```

## Usage

This demo will use [MailHog:](https://github.com/mailhog/MailHog)

```console
$ docker run -d --rm -p 1025:1025 -p 8025:8025 --name mailhog mailhog/mailhog
$ open http://localhost:8025
```

High-level API:

```elixir
message = """
Date: Mon, 25 Dec 2023 06:52:15 +0000\r
From: Mua <mua@github.com>\r
Subject: README\r
To: Mr Receiver <receiver1@mailhog.example>\r
CC: Ms Receiver <receiver2@mailhog.example>\r
\r
like and subscribe\r
.\r
"""

{:ok, _receipt} =
  Mua.easy_send(
    _host = "localhost",
    _mail_from = "mua@github.com",
    _rcpt_to = ["receiver1@mailhog.example", "receiver2@mailhog.example"],
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
    {:ok, _stay_plain_text = socket}
  end

:plain = Mua.pick_auth_method(extensions)
:ok = Mua.auth(socket, :plain, username: "username", password: "password")

:ok = Mua.mail_from(socket, "mua@github.com")
:ok = Mua.rcpt_to(socket, "receiver@mailhog.example")

message =
  """
  Date: Mon, 25 Dec 2023 06:52:15 +0000\r
  From: Mua <mua@github.com>\r
  Subject: How was your day?\r
  To: Mr Receiver <receiver@mailhog.example>\r
  \r
  Mine was fine.\r
  .\r
  """

{:ok, _receipt} = Mua.data(socket, message)
:ok = Mua.close(socket)
```
