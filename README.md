# Mua

Minimal SMTP client (aka Mail user agent).

Can be used with [Bamboo](https://github.com/ruslandoga/bamboo_mua) and [Swoosh.](https://github.com/ruslandoga/swoosh_mua)

### Features

- Direct messaging (no relays)
- Minimal API

## Usage

Single command high-level API:

```elixir
# MAIL FROM:
from = "Ruslan <hey@copycat.fun>"

# RCPT TO:
recipients = [
  "subscriber@gmail.com",
  "follower@gmail.com",
  "reader@hey.com",
  _bcc = "world@hey.com"
]

# there are other packages for message encoding:
# - https://hex.pm/packages/mail
# - https://hex.pm/packages/mailibex
message = """
Date: Sat, 24 Jun 2023 13:43:57 +0000\r
From: hey@copycat.fun\r
Subject: README\r
To: Subscriber <subscriber@gmail.com>, Reader <reader@hey.com>\r
CC: Follower <follower@gmail.com>\r
\r
like and subscribe\r
.\r
"""

default_opts = [
  protocol: :tcp,
  port: 25,
  hostname: Mua.guess_fqdn(),
  timeout: :timer.seconds(15),
  transport_opts: [
    # STARTTLS
    cacertfile: CAStore.file_path(),
    verify: :verify_peer
  ]
]

host = fn recipient ->
  [_user, host] = String.split(recipient, "@")
  host
end

recipients
|> Enum.group_by(host)
|> Enum.map(fn {host, recipients} ->
  Mua.send(host, from, recipients, message, default_opts)
end)
```

Low-level API:

```elixir
{:ok, conn, _banner} = Mua.connect(:tcp, "gmail.com", _port = 25, timeout: :timer.seconds(15))
{:ok, extensions} = Mua.ehlo(conn, hostname: Mua.guess_fqdn())

true = "STARTTLS" in extensions

{:ok, conn} =
  Mua.starttls(conn,
    transport_opts: [
      cacertfile: CAStore.file_path(),
      verify: :verify_peer
    ]
  )

:ok = Mua.mail_from(conn, "hey@copycat.fun")
:ok = Mua.rcpt_to(conn, "dogaruslan@gmail.com")

{:ok, _receipt} =
  Mua.data(conn, """
  Date: Sat, 24 Jun 2023 13:43:57 +0000\r
  From: Ruslan <hey@copycat.fun>\r
  Subject: How was your day?\r
  To: Ruslan <dogaruslan@gmail.com>\r
  \r
  Mine was fine.\r
  .\r
  """)

:ok = Mua.quit(conn)
:ok = Mua.close(conn)
```

### TODOs

- [ ] clean errors
- [ ] port fallback, tcp: 25, tcp: 2525, ssl: 465 + configurable
- [ ] separate packages + swoosh adapter
- [ ] (optional) auth / relay (then port: [tcp: 587])
- [ ] (optional) dkim
- [ ] castore, mint-like tls settings, verify_peer?
- [ ] telemetry (bounces, etc.)
