defmodule Mua do
  @moduledoc """
  TODO
  """

  import Kernel, except: [send: 2]
  require Logger

  @dialyzer :no_improper_lists

  @type conn :: :gen_tcp.socket() | :ssl.sslsocket()

  @doc """
  TODO
  """
  @spec connect(
          proto :: :tcp | :ssl,
          host :: :inet.socket_address() | :inet.hostname() | String.t(),
          port :: :inet.port_number(),
          opts :: Keyword.t()
        ) ::
          {:ok, conn, String.t()} | {:error, term}
  def connect(protocol, host, port, opts \\ []) do
    host =
      case host do
        _ when is_binary(host) -> to_charlist(host)
        _ -> host
      end

    # TODO inet6

    {timeout, opts} = Keyword.pop(opts, :timeout, :timer.seconds(15))
    transport_opts = opts[:transport_opts] || []
    socket_opts = [:binary, active: false, packet: :line] ++ transport_opts

    result =
      case protocol do
        :tcp ->
          :gen_tcp.connect(host, port, socket_opts, timeout)

        :ssl ->
          # TODO deduplicate
          socket_opts = [cacertfile: CAStore.file_path(), verify: :verify_none] ++ socket_opts

          case :ssl.connect(host, port, socket_opts, timeout) do
            {:ok, _conn} = ok -> ok
            {:ok, conn, _extensions} -> {:ok, conn}
            {:error, _reason} = error -> error
            {:option_not_a_key_value_tuple, _} = reason -> {:error, reason}
          end
      end

    with {:ok, conn} <- result do
      case recv_all(conn, timeout) do
        {:ok, [{220, banner} | _rest]} ->
          {:ok, conn, banner}

        {:ok, [{status, _message} | _rest]} ->
          :ok = close(conn)
          {:error, code(status)}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  TODO
  """
  @spec close(conn) :: :ok
  def close(conn) when is_port(conn), do: :gen_tcp.close(conn)

  def close(conn) do
    case :ssl.close(conn) do
      :ok = ok ->
        ok

      {:ok = ok, _port} ->
        ok

      {:ok = ok, _port, _data} ->
        ok
        # TODO
        # {:error, _reason}
    end
  end

  @doc """
  TODO
  """
  @spec send(
          host :: :inet.socket_address() | :inet.hostname() | String.t(),
          sender :: String.t(),
          recipients :: [String.t()],
          message :: iodata,
          opts :: Keyword.t()
        ) :: {:ok, receipt :: String.t()} | {:error, Exception.t()}
  def send(host, sender, recipients, message, opts \\ []) do
    hosts = mxlookup(host)
    send_any(hosts, sender, recipients, message, opts)
  end

  defp send_any([host | hosts], sender, recipients, message, opts) do
    case send_one(host, sender, recipients, message, opts) do
      {:ok, _receipt} = ok ->
        ok

      {:error, _reason} when hosts != [] ->
        # TODO at least log reason
        send_any(hosts, sender, recipients, message, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp send_one(host, sender, recipients, message, opts) do
    port = opts[:port] || 25
    protocol = opts[:protocol] || :tcp
    timeout = opts[:timeout] || :timer.seconds(15)

    with {:ok, conn, _banner} <- connect(protocol, host, port, opts) do
      try do
        hostname = opts[:hostname] || guess_fqdn()

        result =
          case ehlo(conn, hostname, timeout) do
            {:ok, extensions} ->
              if "STARTTLS" in extensions do
                # TODO opts
                starttls(conn, timeout)
              else
                {:ok, conn}
              end

            {:error, :unknown_command} ->
              with :ok <- helo(conn, hostname, timeout) do
                {:ok, conn}
              end

            {:error, _reason} = error ->
              error
          end

        with {:ok, conn} <- result,
             :ok <- mail_from(conn, sender, timeout),
             :ok <- rcpt_to(conn, recipients, timeout),
             do: data(conn, message, timeout)
      after
        quit(conn, timeout)
        close(conn)
      end
    end
  end

  @doc """
  TODO
  """
  @spec ehlo(conn, String.t(), timeout) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def ehlo(conn, hostname, timeout) when is_binary(hostname) do
    with {:ok, [_ | extensions]} <- comm(conn, ["EHLO ", hostname | "\r\n"], 250, timeout) do
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

  @doc """
  TODO
  """
  @spec helo(conn, String.t(), timeout) :: :ok | {:error, Exception.t()}
  def helo(conn, hostname, timeout) when is_binary(hostname) do
    with {:ok = ok, _} <- comm(conn, ["HELO ", hostname | "\r\n"], 250, timeout) do
      ok
    end
  end

  @doc """
  TODO
  """
  @spec starttls(:gen_tcp.socket(), timeout) :: {:ok, :ssl.sslsocket()} | {:error, Exception.t()}
  def starttls(conn, timeout) when is_port(conn) do
    with {:ok, _reply} <- comm(conn, "STARTTLS\r\n", 220, timeout) do
      # TODO verify
      ssl_opts = [cacertfile: CAStore.file_path(), verify: :verify_none]
      :ssl.connect(conn, ssl_opts, timeout)
    end
  end

  @doc """
  TODO
  """
  @spec mail_from(conn, String.t(), timeout) :: :ok | {:error, Exception.t()}
  def mail_from(conn, address, timeout) do
    with {:ok = ok, _} <- comm(conn, ["MAIL FROM: ", quoteaddr(address) | "\r\n"], 250, timeout) do
      ok
    end
  end

  @doc """
  TODO
  """
  @spec rcpt_to(conn, [String.t()], timeout) :: :ok | {:error, Exception.t()}
  def rcpt_to(conn, [address | addresses], timeout) do
    with :ok <- send(conn, ["RCPT TO: ", quoteaddr(address) | "\r\n"]) do
      case recv_all(conn, timeout) do
        {:ok, [{status, _} | _]} when status in [250, 251] ->
          rcpt_to(conn, addresses, timeout)

        {:ok, [{status, _} | _]} ->
          {:error, code(status)}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def rcpt_to(_conn, [], _timeout), do: :ok

  @doc """
  TODO
  """
  @spec data(conn, iodata, timeout) :: {:ok, receipt :: String.t()} | {:error, Exception.t()}
  def data(conn, message, timeout) do
    with {:ok, _} <- comm(conn, "DATA\r\n", 354, timeout),
         {:ok = ok, [receipt]} <- comm(conn, [message | "\r\n.\r\n"], 250, timeout),
         do: {ok, receipt}
  end

  @doc """
  TODO
  """
  @spec vrfy(conn, String.t(), timeout) :: {:ok, boolean} | {:error, Exception.t()}
  def vrfy(conn, address, timeout) do
    case comm(conn, ["VRFY ", quoteaddr(address) | "\r\n"], 250, timeout) do
      {:ok = ok, [_]} -> {ok, true}
      {:error, reason} when reason in [:user_not_local, :vrfy_failed] -> {:ok, false}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  TODO
  """
  @spec quit(conn, timeout) :: :ok | {:error, Exception.t()}
  def quit(conn, timeout) do
    with {:ok = ok, _reply} <- comm(conn, "QUIT\r\n", 221, timeout), do: ok
  end

  @doc """
  TODO
  """
  @spec rset(conn, timeout) :: :ok | {:error, Exception.t()}
  def rset(conn, timeout) do
    with {:ok = ok, _reply} <- comm(conn, "RSET\r\n", 250, timeout), do: ok
  end

  @doc """
  TODO
  """
  @spec noop(conn, timeout) :: :ok | {:error, Exception.t()}
  def noop(conn, timeout) do
    with {:ok = ok, _reply} <- comm(conn, "NOOP\r\n", 250, timeout), do: ok
  end

  # TODO remove
  defp comm(conn, command, status, timeout) do
    with :ok <- send(conn, command) do
      case recv_all(conn, timeout) do
        {:ok, [{^status, _} | _] = chunks} -> {:ok, for({_, line} <- chunks, do: line)}
        {:ok, [{status, _} | _]} -> {:error, code(status)}
        {:error, _reason} = error -> error
      end
    end
  end

  @compile inline: [send: 2]
  defp send(conn, data) when is_port(conn), do: :gen_tcp.send(conn, data)
  defp send(conn, data), do: :ssl.send(conn, data)

  @compile inline: [recv: 3]
  defp recv(conn, size, timeout) when is_port(conn), do: :gen_tcp.recv(conn, size, timeout)
  defp recv(conn, size, timeout), do: :ssl.recv(conn, size, timeout)

  defp recv_all(conn, timeout, acc \\ []) do
    with {:ok, data} <- recv(conn, 0, timeout) do
      <<status::3-bytes, sep, rest::bytes>> = data

      acc = [
        {String.to_integer(status), String.replace(rest, ["\r", "\n"], "")}
        | acc
      ]

      case sep do
        ?- -> recv_all(conn, timeout, acc)
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
