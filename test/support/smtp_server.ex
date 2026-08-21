defmodule Mua.Test.SMTPServer do
  @moduledoc false

  @timeout :timer.seconds(5)

  def start(script) when is_list(script) do
    caller = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        {:ok, listener} =
          :gen_tcp.listen(0,
            ip: {127, 0, 0, 1},
            mode: :binary,
            active: false,
            packet: :line,
            reuseaddr: true
          )

        {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
        send(caller, {ref, port})

        {:ok, socket} = :gen_tcp.accept(listener, @timeout)
        :ok = :gen_tcp.close(listener)

        run(socket, :tcp, script, [])
      end)

    port =
      receive do
        {^ref, port} -> port
      after
        @timeout -> raise "fake SMTP server did not start"
      end

    {task, port}
  end

  def await(task), do: Task.await(task, @timeout * 2)

  defp run(socket, transport, [{:send, data} | script], transcript) do
    :ok = send_data(transport, socket, data)
    run(socket, transport, script, transcript)
  end

  defp run(socket, transport, [{:expect, expected} | script], transcript) do
    case recv(transport, socket) do
      {:ok, ^expected} ->
        run(socket, transport, script, [{transport, expected} | transcript])

      {:ok, received} ->
        raise "expected #{inspect(expected)}, received: #{inspect(received)}"

      {:error, reason} ->
        raise "expected #{inspect(expected)}, socket failed with: #{inspect(reason)}"
    end
  end

  defp run(socket, :tcp, [:starttls | script], transcript) do
    opts =
      :public_key.pkix_test_data(%{
        root: [digest: :sha256, key: {:rsa, 2048, 65_537}],
        peer: [digest: :sha256, key: {:rsa, 2048, 65_537}]
      }) ++
        [verify: :verify_none, active: false, packet: :line, reuse_sessions: false]

    case :ssl.handshake(socket, opts, @timeout) do
      {:ok, socket} -> run(socket, :ssl, script, transcript)
      {:error, reason} -> raise "TLS handshake failed with: #{inspect(reason)}"
    end
  end

  defp run(socket, transport, [:expect_close | script], transcript) do
    case recv(transport, socket) do
      {:error, :closed} ->
        run(socket, transport, script, transcript)

      {:error, {:tls_alert, {:close_notify, _description}}} ->
        run(socket, transport, script, transcript)

      {:ok, received} ->
        raise "expected the client to close, received: #{inspect(received)}"

      {:error, reason} ->
        raise "expected the client to close, got: #{inspect(reason)}"
    end
  end

  defp run(socket, transport, [], transcript) do
    _ = close(transport, socket)
    Enum.reverse(transcript)
  end

  defp send_data(:tcp, socket, data), do: :gen_tcp.send(socket, data)
  defp send_data(:ssl, socket, data), do: :ssl.send(socket, data)

  defp recv(:tcp, socket), do: :gen_tcp.recv(socket, 0, @timeout)
  defp recv(:ssl, socket), do: :ssl.recv(socket, 0, @timeout)

  defp close(:tcp, socket), do: :gen_tcp.close(socket)
  defp close(:ssl, socket), do: :ssl.close(socket)
end
