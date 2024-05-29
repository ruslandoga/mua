# Changelog

## Unreleased

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
