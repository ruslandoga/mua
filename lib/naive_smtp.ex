defmodule NaiveSMTP do
  @moduledoc """
  TODO
  """

  import Kernel, except: [send: 2]
  require Logger

  @type conn :: :gen_tcp.socket() | :ssl.sslsocket()

  @spec connect(:inet.socket_address() | :inet.hostname(), Keyword.t()) ::
          {:ok, :gen_tcp.socket(), String.t()} | {:error, term}
  def connect(host, opts \\ []) do
    host =
      case host do
        _ when is_binary(host) -> to_charlist(host)
        _ -> host
      end

    {timeout, opts} = Keyword.pop(opts, :timeout, :timer.seconds(15))
    transport_opts = opts[:transport_opts] || []
    socket_opts = [:binary, active: false, packet: :line] ++ transport_opts

    Logger.debug("connecting to #{inspect(host)} on port 25")

    case :gen_tcp.connect(host, 25, socket_opts, timeout) do
      {:ok, conn} ->
        case recv(conn, timeout) do
          {:ok, [{220, banner} | _rest]} ->
            # TODO starttls here?
            {:ok, conn, banner}

          {:ok, [{status, _message} | _rest]} ->
            {:error, code(status)}

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  def send(email, opts \\ []) do
    envelop = wrap(email)

    # TODO
    email.recipients
    |> Enum.group_by(fn recipient ->
      [_, host] = String.split(recipient, "@")
      host
    end)
    |> Enum.map(fn {host, _recipients} ->
      send_any(mxlookup(host), _port = 25, envelop, opts)
    end)
  end

  @doc false
  def wrap(email, now \\ DateTime.utc_now()) do
    date = Calendar.strftime(now, "%a, %d %b %Y %H:%M:%S %z")

    headers = [
      {"Date", date},
      {"From", email.sender},
      {"To", Enum.intersperse(email.recipients, ", ")},
      {"Subject", email.subject}
    ]

    headers = :lists.ukeysort(1, email.headers ++ headers)
    headers = for {k, v} <- headers, do: [k, ": ", v, "\r\n"]

    {
      email.sender,
      email.recipients,
      [headers, "\r\n" | email.message]
    }
  end

  defp send_any([host | hosts], port, envelope, opts) do
    case send_one(host, port, envelope, opts) do
      {:ok, _receipt} = ok ->
        ok

      {:error, reason}
      when reason in [
             :service_not_available,
             :mailbox_unavailable,
             :local_error,
             :insufficient_system_storage
           ] and
             hosts != [] ->
        send_any(hosts, port, envelope, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp send_one(host, _port, envelope, opts) do
    with {:ok, conn, _banner} <- connect(host, opts) do
      try do
        check_and_send(conn, envelope, opts)
      after
        disconnect(conn)
      end
    end
  end

  @doc false
  def check_and_send(conn, envelop, opts) do
    case do_check(conn, opts) do
      {:ok, conn} -> do_send(conn, envelop, opts)
      {:error, _reason} = error -> error
    end
  end

  def disconnect(conn) when is_port(conn), do: :gen_tcp.close(conn)
  def disconnect(conn), do: :ssl.close(conn)

  # helpers

  defp do_check(conn, opts) do
    hostname = opts[:hostname] || guess_fqdn()
    timeout = opts[:timeout] || :timer.seconds(15)

    case do_ehlo(conn, hostname, timeout) do
      {:ok, extensions} -> do_starttls(conn, extensions, opts)
      {:error, _reason} = error -> error
    end
  end

  defp do_ehlo(conn, hostname, timeout) do
    case ehlo(conn, hostname, timeout) do
      {:error, :unknown_command} -> helo(conn, hostname, timeout)
      {_, _} = result -> result
    end
  end

  defp do_starttls(conn, extensions, opts) do
    timeout = opts[:timeout] || :timer.seconds(15)

    if "STARTTLS" in extensions do
      starttls(conn, timeout)
    else
      {:ok, conn}
    end
  end

  defp do_send(conn, {sender, recipients, message}, opts) do
    timeout = opts[:timeout] || :timer.seconds(15)

    with {:ok, _} <- mail(conn, sender, timeout),
         :ok <- rcpt(conn, recipients, timeout),
         do: data(conn, message, timeout)
  end

  # smtp commands

  defp ehlo(conn, hostname, timeout) when is_binary(hostname) do
    with {:ok, [_ | extensions]} <- communicate(conn, ["EHLO ", hostname | "\r\n"], 250, timeout) do
      extensions =
        Enum.map(extensions, fn extension ->
          case String.split(extension, " ") do
            [name] -> name
            [name, value] -> {name, value}
          end
        end)

      {:ok, extensions}
    end
  end

  defp helo(conn, hostname, timeout) when is_binary(hostname) do
    communicate(conn, ["HELO ", hostname | "\r\n"], 250, timeout)
  end

  defp starttls(conn, timeout) when is_port(conn) do
    with {:ok, _reply} <- communicate(conn, "STARTTLS\r\n", 220, timeout) do
      # TODO verify
      ssl_opts = [cacertfile: CAStore.file_path(), verify: :verify_none]
      :ssl.connect(conn, ssl_opts, timeout)
    end
  end

  defp starttls(_conn, _timeout), do: {:error, :already_ssl}

  defp mail(conn, address, timeout) do
    communicate(conn, ["MAIL FROM: ", quoteaddr(address) | "\r\n"], 250, timeout)
  end

  defp rcpt(conn, [address | addresses], timeout) do
    :ok = __send(conn, ["RCPT TO: ", quoteaddr(address) | "\r\n"])

    case recv(conn, timeout) do
      {:ok, [{status, _}]} when status in [250, 251] ->
        rcpt(conn, addresses, timeout)

      {:ok, [{status, _} | _]} ->
        {:error, code(status)}

      {:error, _reason} = error ->
        error
    end
  end

  defp rcpt(_conn, [], _timeout), do: :ok

  defp data(conn, message, timeout) do
    with {:ok, _} <- communicate(conn, "DATA\r\n", 354, timeout),
         {:ok = ok, [receipt]} <- communicate(conn, [message | "\r\n.\r\n"], 250, timeout),
         do: {ok, receipt}
  end

  defp vrfy(conn, address, timeout) do
    case communicate(conn, ["VRFY ", quoteaddr(address) | "\r\n"], 250, timeout) do
      {:ok, [_]} -> true
      {:error, :user_not_local} -> false
      {:error, :vrfy_failed} -> false
      {:error, _reason} = error -> error
    end
  end

  defp quit(conn, timeout) do
    with {:ok = ok, _reply} <- communicate(conn, "QUIT\r\n", 221, timeout), do: ok
  end

  defp rset(conn, timeout) do
    with {:ok = ok, _reply} <- communicate(conn, "RSET\r\n", 250, timeout), do: ok
  end

  defp noop(conn, timeout) do
    with {:ok = ok, _reply} <- communicate(conn, "NOOP\r\n", 250, timeout), do: ok
  end

  # low level api

  defp communicate(conn, command, status, timeout) do
    :ok = __send(conn, command)

    case recv(conn, timeout) do
      {:ok, [{^status, _} | _] = chunks} -> {:ok, for({_, line} <- chunks, do: line)}
      {:ok, [{status, _} | _]} -> {:error, code(status)}
      {:error, _reason} = error -> error
    end
  end

  defp __send(conn, data) do
    Logger.debug(data)
    _send(conn, data)
  end

  @compile inline: [_send: 2]
  defp _send(conn, data) when is_port(conn), do: :gen_tcp.send(conn, data)
  defp _send(conn, data), do: :ssl.send(conn, data)

  @compile inline: [_recv: 3]
  defp _recv(conn, size, timeout) when is_port(conn), do: :gen_tcp.recv(conn, size, timeout)
  defp _recv(conn, size, timeout), do: :ssl.recv(conn, size, timeout)

  defp recv(conn, timeout), do: recv(conn, timeout, [])

  defp recv(conn, timeout, acc) do
    with {:ok, data} <- _recv(conn, 0, timeout) do
      Logger.debug(data)
      <<status::3-bytes, sep, rest::bytes>> = data

      acc = [
        {String.to_integer(status), String.replace(rest, ["\r", "\n"], "")}
        | acc
      ]

      case sep do
        ?- -> recv(conn, timeout, acc)
        ?\s -> {:ok, :lists.reverse(acc)}
      end
    end
  end

  defp code(200), do: :success
  defp code(211), do: :help
  defp code(220), do: :service_ready
  defp code(221), do: :service_closing
  defp code(250), do: :action_completed
  defp code(251), do: :user_not_local
  defp code(252), do: :vrfy_failed
  defp code(421), do: :service_not_available
  defp code(450), do: :mailbox_unavailable
  defp code(451), do: :local_error
  defp code(452), do: :insufficient_system_storage
  defp code(454), do: :tls_not_available
  defp code(500), do: :unknown_command
  defp code(501), do: :invalid_arguments
  defp code(502), do: :not_implemnted
  defp code(503), do: :unexpected_command
  defp code(530), do: :access_denied
  defp code(535), do: :authentication_failed
  defp code(550), do: :mailbox_unavailable
  defp code(551), do: :user_not_local
  defp code(553), do: :mailbox_syntax_incorrect
  defp code(554), do: :transaction_failed

  defp quoteaddr(""), do: "<>"

  defp quoteaddr(address) when is_binary(address) do
    # This is by no means a complete RFC2822 implementation -- just
    # a quick way to fix the address, in case it's not wrapped in
    # angle brackets.
    but_last = byte_size(address) - 1

    case address do
      <<_::size(but_last)-bytes, ?>>> -> address
      _ -> [?<, address, ?>]
    end
  end

  @doc false
  def recipient_host(recipient) do
    [_, host] = String.split(recipient, "@")
  end

  require Record
  Record.defrecord(:hostent, Record.extract(:hostent, from_lib: "kernel/include/inet.hrl"))

  # returns a sorted list of mx servers for `domain', lowest distance first
  # copied from gen_smtp
  @doc false
  def mxlookup(domain) do
    case :erlang.whereis(:inet_db) do
      p when is_pid(p) -> :ok
      _ -> :inet_db.start()
    end

    case :lists.keyfind(:nameserver, 1, :inet_db.get_rc()) do
      false ->
        # we got no nameservers configured, suck in resolv.conf
        :inet_config.do_load_resolv(:os.type(), :longnames)

      _ ->
        :ok
    end

    domain = to_charlist(domain)

    case :inet_res.lookup(domain, :in, :mx) do
      [] -> [domain]
      result -> result |> :lists.sort() |> Enum.map(fn {_, host} -> host end)
    end
  end

  @doc false
  def guess_fqdn do
    with {:ok, hostname} <- :inet.gethostname(),
         {:ok, hostent(h_name: fqdn)} <- :inet.gethostbyname(hostname) do
      to_string(fqdn)
    else
      error ->
        Logger.error(where: "guess_fqdn", error: error)
        "localhost"
    end
  end
end
