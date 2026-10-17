defmodule Mua.PoolTest do
  use ExUnit.Case, async: true

  # Mailpit covers real-server integration, but it does not expose connection
  # counts or command traces and cannot deterministically stall or close a
  # specific SMTP session. This server supplies those pool lifecycle controls.
  defmodule FakeSMTPServer do
    use GenServer

    def child_spec(opts) do
      %{
        id: Keyword.fetch!(opts, :id),
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def port(server) do
      GenServer.call(server, :port)
    end

    def stats(server) do
      GenServer.call(server, :stats)
    end

    @impl GenServer
    def init(opts) do
      listen_opts = [
        :binary,
        ip: {127, 0, 0, 1},
        packet: :line,
        active: false,
        reuseaddr: true
      ]

      {:ok, listener} = :gen_tcp.listen(0, listen_opts)
      {:ok, {_address, port}} = :inet.sockname(listener)

      server = self()
      acceptor = spawn_link(fn -> accept_loop(listener, server) end)

      {:ok,
       %{
         acceptor: acceptor,
         block_data: Keyword.get(opts, :block_data, false),
         close_after_data: Keyword.get(opts, :close_after_data, false),
         close_after_checkin: Keyword.get(opts, :close_after_checkin, false),
         commands: [],
         connections: 0,
         fail_reset: Keyword.get(opts, :fail_reset, false),
         listener: listener,
         observer: Keyword.fetch!(opts, :observer),
         port: port,
         reject_recipients: Keyword.get(opts, :reject_recipients, [])
       }}
    end

    @impl GenServer
    def handle_call(:port, _from, state) do
      {:reply, state.port, state}
    end

    def handle_call(:stats, _from, state) do
      stats = %{
        commands: Enum.reverse(state.commands),
        connections: state.connections
      }

      {:reply, stats, state}
    end

    def handle_call(:accepted, _from, state) do
      connection = state.connections + 1
      {:reply, connection, %{state | connections: connection}}
    end

    def handle_call({:command, connection, kind, line}, _from, state) do
      response =
        cond do
          kind == :rcpt_to and
              Enum.any?(state.reject_recipients, fn recipient ->
                String.contains?(line, recipient)
              end) ->
            :reject

          kind == :rset and state.fail_reset ->
            :fail

          kind == :data and state.close_after_data ->
            :close

          kind == :data and state.close_after_checkin ->
            {:close_after_checkin, state.observer}

          kind == :data and state.block_data ->
            {:block, state.observer}

          true ->
            :ok
        end

      command = {connection, kind, line}
      state = %{state | commands: [command | state.commands]}

      state =
        case response do
          :fail -> %{state | fail_reset: false}
          {:close_after_checkin, _observer} -> %{state | close_after_checkin: false}
          _response -> state
        end

      {:reply, response, state}
    end

    @impl GenServer
    def handle_cast({:closed, connection}, state) do
      send(state.observer, {:smtp_connection_closed, self(), connection})
      {:noreply, state}
    end

    @impl GenServer
    def terminate(_reason, state) do
      :gen_tcp.close(state.listener)
    end

    defp accept_loop(listener, server) do
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          handler =
            spawn(fn ->
              receive do
                {:serve, socket} -> serve(socket, server)
              end
            end)

          :ok = :gen_tcp.controlling_process(socket, handler)
          send(handler, {:serve, socket})
          accept_loop(listener, server)

        {:error, :closed} ->
          :ok
      end
    end

    defp serve(socket, server) do
      connection = GenServer.call(server, :accepted)
      :ok = :gen_tcp.send(socket, "220 fake-smtp ESMTP ready\r\n")
      command_loop(socket, server, connection)
    end

    defp command_loop(socket, server, connection) do
      case :gen_tcp.recv(socket, 0, :infinity) do
        {:ok, line} ->
          kind = command_kind(line)
          response = GenServer.call(server, {:command, connection, kind, line})
          respond(socket, server, connection, kind, response)

        {:error, :closed} ->
          GenServer.cast(server, {:closed, connection})
          :ok
      end
    end

    defp respond(socket, server, connection, :ehlo, _reject?) do
      :ok = :gen_tcp.send(socket, "250-fake-smtp\r\n250 AUTH PLAIN\r\n")
      command_loop(socket, server, connection)
    end

    defp respond(socket, server, connection, :helo, _reject?) do
      :ok = :gen_tcp.send(socket, "250 fake-smtp\r\n")
      command_loop(socket, server, connection)
    end

    defp respond(socket, server, connection, :mail_from, _reject?) do
      :ok = :gen_tcp.send(socket, "250 sender accepted\r\n")
      command_loop(socket, server, connection)
    end

    defp respond(socket, server, connection, :rcpt_to, :reject) do
      :ok = :gen_tcp.send(socket, "550 recipient rejected\r\n")
      command_loop(socket, server, connection)
    end

    defp respond(socket, server, connection, :rcpt_to, _response) do
      :ok = :gen_tcp.send(socket, "250 recipient accepted\r\n")
      command_loop(socket, server, connection)
    end

    defp respond(socket, _server, _connection, :data, :close) do
      :ok = :gen_tcp.send(socket, "354 send message\r\n")
      :ok = receive_data(socket)
      :ok = :gen_tcp.send(socket, "250 queued\r\n")
      :gen_tcp.close(socket)
    end

    defp respond(socket, server, connection, :data, {:block, observer}) do
      :ok = :gen_tcp.send(socket, "354 send message\r\n")
      :ok = receive_data(socket)
      send(observer, {:smtp_data_waiting, self()})

      receive do
        :continue_data -> :ok
      end

      :ok = :gen_tcp.send(socket, "250 queued\r\n")
      command_loop(socket, server, connection)
    end

    defp respond(socket, server, connection, :data, {:close_after_checkin, observer}) do
      :ok = :gen_tcp.send(socket, "354 send message\r\n")
      :ok = receive_data(socket)
      :ok = :gen_tcp.send(socket, "250 queued\r\n")
      send(observer, {:smtp_delivery_complete, self(), connection})

      receive do
        :close_connection -> :ok
      end

      :ok = :gen_tcp.close(socket)
      GenServer.cast(server, {:closed, connection})
    end

    defp respond(socket, server, connection, :data, _response) do
      :ok = :gen_tcp.send(socket, "354 send message\r\n")
      :ok = receive_data(socket)
      :ok = :gen_tcp.send(socket, "250 queued\r\n")
      command_loop(socket, server, connection)
    end

    defp respond(socket, server, connection, :rset, :fail) do
      :ok = :gen_tcp.send(socket, "500 reset failed\r\n")
      command_loop(socket, server, connection)
    end

    defp respond(socket, server, connection, :rset, _response) do
      :ok = :gen_tcp.send(socket, "250 reset\r\n")
      command_loop(socket, server, connection)
    end

    defp respond(socket, server, connection, :auth, _response) do
      :ok = :gen_tcp.send(socket, "235 authenticated\r\n")
      command_loop(socket, server, connection)
    end

    defp respond(socket, _server, _connection, :quit, _reject?) do
      :ok = :gen_tcp.send(socket, "221 goodbye\r\n")
      :gen_tcp.close(socket)
    end

    defp respond(socket, server, connection, :unknown, _reject?) do
      :ok = :gen_tcp.send(socket, "500 unknown command\r\n")
      command_loop(socket, server, connection)
    end

    defp receive_data(socket) do
      case :gen_tcp.recv(socket, 0, :infinity) do
        {:ok, ".\r\n"} -> :ok
        {:ok, _line} -> receive_data(socket)
        {:error, reason} -> {:error, reason}
      end
    end

    defp command_kind(line) do
      cond do
        String.starts_with?(line, "EHLO ") -> :ehlo
        String.starts_with?(line, "HELO ") -> :helo
        String.starts_with?(line, "MAIL FROM:") -> :mail_from
        String.starts_with?(line, "RCPT TO:") -> :rcpt_to
        String.starts_with?(line, "AUTH PLAIN ") -> :auth
        line == "DATA\r\n" -> :data
        line == "RSET\r\n" -> :rset
        line == "QUIT\r\n" -> :quit
        true -> :unknown
      end
    end
  end

  test "starting a pool opens no SMTP connections" do
    server = start_server()
    _pool = start_pool(pool_size: 2)

    assert FakeSMTPServer.stats(server).connections == 0
  end

  test "sequential sends reuse one connection and one EHLO" do
    server = start_server()
    pool = start_pool(pool_size: 2)

    assert {:ok, "250 queued\r\n"} = send_email(server, pool, "first@example.test")
    assert {:ok, "250 queued\r\n"} = send_email(server, pool, "second@example.test")

    stats = FakeSMTPServer.stats(server)

    assert stats.connections == 1
    assert command_count(stats, :ehlo) == 1
    assert command_count(stats, :mail_from) == 2
    assert command_count(stats, :data) == 2
    assert command_count(stats, :rset) == 0
  end

  test "a rejected recipient is reset and the connection is reused" do
    server = start_server(reject_recipients: ["reject@example.test"])
    pool = start_pool(pool_size: 1)

    assert {:error, %Mua.SMTPError{code: 550}} =
             send_email(server, pool, "reject@example.test")

    assert {:ok, "250 queued\r\n"} = send_email(server, pool, "accepted@example.test")

    stats = FakeSMTPServer.stats(server)

    assert stats.connections == 1
    assert command_count(stats, :ehlo) == 1

    assert command_kinds(stats) == [
             :ehlo,
             :mail_from,
             :rcpt_to,
             :rset,
             :mail_from,
             :rcpt_to,
             :data
           ]
  end

  test "different destination ports use different connection pools" do
    first_server = start_server()
    second_server = start_server()
    pool = start_pool(pool_size: 1)

    assert {:ok, "250 queued\r\n"} =
             send_email(first_server, pool, "first@example.test")

    assert {:ok, "250 queued\r\n"} =
             send_email(second_server, pool, "second@example.test")

    assert %{connections: 1} = first_stats = FakeSMTPServer.stats(first_server)
    assert %{connections: 1} = second_stats = FakeSMTPServer.stats(second_server)
    assert command_count(first_stats, :ehlo) == 1
    assert command_count(second_stats, :ehlo) == 1
  end

  test "the complete connection configuration isolates sessions" do
    server = start_server()
    pool = start_pool(pool_size: 1)

    assert {:ok, _receipt} = send_email(server, pool, "baseline@example.test")

    assert {:ok, _receipt} =
             send_email(server, pool, "helo@example.test", sender: "sender@other.test")

    assert {:ok, _receipt} =
             send_email(server, pool, "auth@example.test",
               auth: [username: "username", password: "password"]
             )

    assert {:ok, _receipt} =
             send_email(server, pool, "tcp-options@example.test", tcp: [nodelay: true])

    assert {:ok, _receipt} =
             send_email(server, pool, "tls-options@example.test", ssl: [verify: :verify_none])

    stats = FakeSMTPServer.stats(server)
    assert stats.connections == 5
    assert command_count(stats, :ehlo) == 5
    assert command_count(stats, :auth) == 1
  end

  test "a failed reset evicts the connection" do
    server =
      start_server(
        fail_reset: true,
        reject_recipients: ["reject@example.test"]
      )

    pool = start_pool(pool_size: 1)

    assert {:error, %Mua.SMTPError{code: 550}} =
             send_email(server, pool, "reject@example.test")

    assert {:ok, "250 queued\r\n"} = send_email(server, pool, "accepted@example.test")

    stats = FakeSMTPServer.stats(server)
    assert stats.connections == 2
    assert command_count(stats, :ehlo) == 2
  end

  test "a connection closed while idle is replaced" do
    server = start_server(close_after_data: true)
    pool = start_pool(pool_size: 1)

    assert {:ok, "250 queued\r\n"} = send_email(server, pool, "first@example.test")
    assert {:ok, "250 queued\r\n"} = send_email(server, pool, "second@example.test")

    stats = FakeSMTPServer.stats(server)
    assert stats.connections == 2
    assert command_count(stats, :ehlo) == 2
  end

  test "an unsolicited close after checkin removes the idle connection" do
    server = start_server(close_after_checkin: true)
    pool = start_pool(pool_size: 1)

    assert {:ok, "250 queued\r\n"} = send_email(server, pool, "first@example.test")
    assert_receive {:smtp_delivery_complete, handler, 1}, 1_000

    destination_pool = destination_pool(pool)
    assert_eventually(fn -> pool_resource_count(destination_pool) == 1 end)

    send(handler, :close_connection)
    assert_receive {:smtp_connection_closed, ^server, 1}, 1_000
    assert_eventually(fn -> pool_resource_count(destination_pool) == 0 end)

    assert {:ok, "250 queued\r\n"} = send_email(server, pool, "second@example.test")

    stats = FakeSMTPServer.stats(server)
    assert stats.connections == 2
    assert command_count(stats, :ehlo) == 2
  end

  test "a caller crash releases its destination pool lease" do
    server = start_server(block_data: true)
    pool = start_pool(pool_max_idle_time: 0, pool_size: 1)

    caller =
      spawn(fn ->
        send_email(server, pool, "recipient@example.test")
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:smtp_data_waiting, handler}, 1_000

    destination_pool = destination_pool(pool)
    pool_monitor = Process.monitor(destination_pool)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^pool_monitor, :process, ^destination_pool, _reason}, 1_000

    Process.exit(handler, :kill)
  end

  test "a connection is closed when session setup raises" do
    server = start_server()
    pool = start_pool(pool_size: 1)

    assert_raise KeyError, fn ->
      Mua.easy_send(
        {127, 0, 0, 1},
        "sender@example.test",
        ["recipient@example.test"],
        "Subject: pooling\r\n\r\nhello",
        auth: [username: "missing-password"],
        pool: pool,
        port: FakeSMTPServer.port(server),
        timeout: 2_000
      )
    end

    assert_receive {:smtp_connection_closed, ^server, 1}, 1_000
  end

  test "an idle destination pool expires and is recreated on demand" do
    server = start_server()
    pool = start_pool(pool_max_idle_time: 0, pool_size: 1)

    assert {:ok, "250 queued\r\n"} = send_email(server, pool, "first@example.test")
    assert_receive {:smtp_connection_closed, ^server, 1}, 1_000

    assert {:ok, "250 queued\r\n"} = send_email(server, pool, "second@example.test")

    stats = FakeSMTPServer.stats(server)
    assert stats.connections == 2
    assert command_count(stats, :ehlo) == 2
  end

  test "a checkout timeout is returned as a transport error" do
    server = start_server(block_data: true)
    pool = start_pool(pool_size: 1)

    delivery =
      Task.async(fn ->
        send_email(server, pool, "first@example.test")
      end)

    assert_receive {:smtp_data_waiting, handler}, 1_000

    assert {:error, %Mua.TransportError{reason: :timeout}} =
             send_email(server, pool, "second@example.test", pool_timeout: 10)

    send(handler, :continue_data)
    assert {:ok, "250 queued\r\n"} = Task.await(delivery, 2_000)
  end

  test "a manager stopping during pool lookup returns a transport error" do
    server = start_server()
    pool = start_pool(pool_size: 1)
    manager = Process.whereis(Mua.Pool.manager_name(pool))
    :ok = :sys.suspend(manager)

    {caller, caller_monitor, result_ref} =
      spawn_delivery(fn -> send_email(server, pool, "recipient@example.test") end)

    assert_eventually(fn -> call_queued?(manager, caller) end)
    Process.exit(manager, :kill)

    assert_receive {^result_ref, {:error, %Mua.TransportError{reason: :closed}}}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
  end

  test "a destination pool stopping during checkout returns a transport error" do
    server = start_server()
    pool = start_pool(pool_size: 1)

    assert {:ok, "250 queued\r\n"} = send_email(server, pool, "first@example.test")

    destination_pool = destination_pool(pool)
    :ok = :sys.suspend(destination_pool)

    {caller, caller_monitor, result_ref} =
      spawn_delivery(fn -> send_email(server, pool, "second@example.test") end)

    assert_eventually(fn -> call_queued?(destination_pool, caller) end)
    Process.exit(destination_pool, :kill)

    assert_receive {^result_ref, {:error, %Mua.TransportError{reason: :closed}}}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000

    assert {:ok, "250 queued\r\n"} = send_email(server, pool, "third@example.test")
    assert FakeSMTPServer.stats(server).connections == 2
  end

  test "pool_size allows concurrent deliveries" do
    server = start_server(block_data: true)
    pool = start_pool(pool_size: 2)

    first =
      Task.async(fn ->
        send_email(server, pool, "first@example.test")
      end)

    second =
      Task.async(fn ->
        send_email(server, pool, "second@example.test")
      end)

    assert_receive {:smtp_data_waiting, first_handler}, 1_000
    assert_receive {:smtp_data_waiting, second_handler}, 1_000
    refute first_handler == second_handler

    send(first_handler, :continue_data)
    send(second_handler, :continue_data)

    assert {:ok, "250 queued\r\n"} = Task.await(first, 2_000)
    assert {:ok, "250 queued\r\n"} = Task.await(second, 2_000)

    assert FakeSMTPServer.stats(server).connections == 2
  end

  defp start_server(opts \\ []) do
    id = {FakeSMTPServer, System.unique_integer([:positive, :monotonic])}

    opts =
      opts
      |> Keyword.put(:id, id)
      |> Keyword.put(:observer, self())

    start_supervised!({FakeSMTPServer, opts})
  end

  defp start_pool(opts) do
    suffix = System.unique_integer([:positive, :monotonic])
    name = :"Mua.PoolTest.Pool#{suffix}"

    start_supervised!({Mua.Pool, Keyword.put(opts, :name, name)})
    name
  end

  defp send_email(server, pool, recipient, opts \\ []) do
    {sender, opts} = Keyword.pop(opts, :sender, "sender@example.test")

    opts =
      Keyword.merge(
        [
          pool: pool,
          port: FakeSMTPServer.port(server),
          timeout: 2_000,
          pool_timeout: 2_000
        ],
        opts
      )

    Mua.easy_send(
      {127, 0, 0, 1},
      sender,
      [recipient],
      "Subject: pooling\r\n\r\nhello",
      opts
    )
  end

  defp command_count(stats, kind) do
    Enum.count(stats.commands, fn {_connection, command, _line} -> command == kind end)
  end

  defp command_kinds(stats) do
    Enum.map(stats.commands, fn {_connection, command, _line} -> command end)
  end

  defp spawn_delivery(delivery) do
    parent = self()
    result_ref = make_ref()

    {caller, monitor} =
      spawn_monitor(fn ->
        send(parent, {result_ref, delivery.()})
      end)

    {caller, monitor, result_ref}
  end

  defp call_queued?(server, caller) do
    case Process.info(server, :messages) do
      {:messages, messages} ->
        Enum.any?(messages, fn
          {:"$gen_call", {^caller, _ref}, _request} -> true
          _message -> false
        end)

      nil ->
        false
    end
  end

  defp destination_pool(pool) do
    %{pools: pools} = :sys.get_state(Mua.Pool.manager_name(pool))
    [%{pid: destination_pool}] = Map.values(pools)
    destination_pool
  end

  defp pool_resource_count(pool) do
    pool
    |> :sys.get_state()
    |> Map.fetch!(:resources)
    |> :queue.len()
  end

  defp assert_eventually(assertion, attempts \\ 100)

  defp assert_eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(assertion, attempts - 1)
    end
  end

  defp assert_eventually(assertion, 0) do
    assert assertion.()
  end
end
