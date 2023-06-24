defmodule BambooNaiveSmtpTest do
  use ExUnit.Case
  doctest BambooNaiveSmtp

  test "greets the world" do
    assert BambooNaiveSmtp.hello() == :world
  end
end
