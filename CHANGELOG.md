# Changelog

## v0.2.3 (2024-07-12)

- remove unused `guess_sender_hostname/0` https://github.com/ruslandoga/mua/pull/48
- allow skipping MX lookup (useful when using relays) https://github.com/ruslandoga/mua/pull/55

## v0.2.2 (2024-06-10)

- default to `:public_key.cacerts_get/0` instead of `CAStore`

## v0.2.1 (2024-05-30)

- improve docs

## v0.2.0 (2024-05-29)

- split transport opts by protocol (tcp/ssl) https://github.com/ruslandoga/mua/pull/44

## v0.1.6 (2024-02-27)

- support Elixir v1.13 for Swoosh integration

## v0.1.5 (2023-12-26)

- cleanup API and update docs

## v0.1.4 (2023-09-09)

- do `EHLO` or `HELO` after `STARTTLS` https://github.com/ruslandoga/mua/pull/7

## v0.1.3 (2023-07-14)

- add `Mua.TransportError` like in [Mint](https://github.com/elixir-mint/mint/blob/main/lib/mint/transport_error.ex) https://github.com/ruslandoga/mua/pull/6

## v0.1.2 (2023-07-14)

- refactor `AUTH` https://github.com/ruslandoga/mua/pull/5

## v0.1.1 (2023-07-14)

- add `AUTH` https://github.com/ruslandoga/mua/pull/4
