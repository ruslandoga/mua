# Mua

[![Hex Package](https://img.shields.io/hexpm/v/mua.svg)](https://hex.pm/packages/mua)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/mua)

Minimal SMTP client (aka Mail user agent).

Can be used with [Bamboo](https://github.com/ruslandoga/bamboo_mua) and [Swoosh.](https://github.com/ruslandoga/swoosh_mua)

### Features

- Direct messaging (no relays)
- Minimal API

Your ideas are welcome [here.](https://github.com/ruslandoga/mua/issues/2)

## Installation

```elixir
defp deps do
  [
    {:mua, "~> 0.1.0"}
  ]
end
```

## Usage

Single command high-level API:

```elixir
# MAIL FROM:
from = "hey@copycat.fun"

# RCPT TO:
recipients = [
  "dogaruslan@gmail.com",
  "ruslan.doga@ya.ru"
]

# check out these packages for message encoding:
# - https://hex.pm/packages/mail
# - https://hex.pm/packages/mailibex
message = """
Date: Sat, 24 Jun 2023 13:43:57 +0000\r
From: Ruslan <hey@copycat.fun>\r
Subject: README\r
To: Ruslan <dogaruslan@gmail.com>\r
CC: Ruslan <ruslan.doga@ya.ru>\r
\r
like and subscribe\r
.\r
"""

host = fn recipient ->
  [_user, host] = String.split(recipient, "@")
  host
end

recipients
|> Enum.group_by(host)
|> Enum.map(fn {host, recipients} ->
  {host, Mua.easy_send(host, from, recipients, message)}
end)
```

Low-level API:

```elixir
[host | _rest] = Mua.mxlookup("gmail.com")
{:ok, socket, _banner} = Mua.connect(:tcp, host, _port = 25)

{:ok, our_hostname} = Mua.guess_fqdn()
{:ok, extensions} = Mua.ehlo(socket, our_hostname)

true = "STARTTLS" in extensions
{:ok, socket} = Mua.starttls(socket, host)

:ok = Mua.mail_from(socket, "hey@copycat.fun")
:ok = Mua.rcpt_to(socket, "dogaruslan@gmail.com")

{:ok, _receipt} =
  Mua.data(socket, """
  Date: Sat, 24 Jun 2023 13:43:57 +0000\r
  From: Ruslan <hey@copycat.fun>\r
  Subject: How was your day?\r
  To: Ruslan <dogaruslan@gmail.com>\r
  \r
  Mine was fine.\r
  .\r
  """)

:ok = Mua.quit(socket)
:ok = Mua.close(socket)
```
