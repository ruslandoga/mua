defmodule Mua do
  @moduledoc """
  Minimal SMTP client.
  """

  import Kernel, except: [send: 2]
  require Logger

  @dialyzer :no_improper_lists

  @type socket :: :gen_tcp.socket() | :ssl.sslsocket()
  @type host :: :inet.socket_address() | :inet.hostname() | String.t()

  @default_timeout :timer.seconds(30)

  @doc """
  Utility function to lookup MX servers for a domain.

      ["gmail-smtp-in.l.google.com" | _rest] = mxlookup("gmail.com")

  """
  @spec mxlookup(String.t()) :: [String.t()]
  def mxlookup(domain) when is_binary(domain) do
    # TODO need it?
    case :erlang.whereis(:inet_db) do
      p when is_pid(p) -> :ok
      _ -> :inet_db.start()
    end

    # TODO need it?
    case :lists.keyfind(:nameserver, 1, :inet_db.get_rc()) do
      false ->
        # we got no nameservers configured, suck in resolv.conf
        :inet_config.do_load_resolv(:os.type(), :longnames)

      _ ->
        :ok
    end

    :inet_res.lookup(to_charlist(domain), :in, :mx)
    |> :lists.sort()
    |> Enum.map(fn {_, host} -> List.to_string(host) end)
  end

  require Record
  Record.defrecordp(:hostent, Record.extract(:hostent, from_lib: "kernel/include/inet.hrl"))

  @doc """
  Utility function to guess the local FQDN.

      {:ok, "mac3"} = guess_fqdn()

  """
  @spec guess_fqdn :: {:ok, String.t()} | {:error, :inet.posix()}
  def guess_fqdn do
    with {:ok, hostname} <- :inet.gethostname(),
         {:ok, hostent(h_name: fqdn)} <- :inet.gethostbyname(hostname),
         do: {:ok, List.to_string(fqdn)}
  end

  @doc """
  Utility function to send a message to a list of recipients on a host.

      {:ok, _receipt} =
        easy_send(
          _host = "gmail.com",
          _sender = "hey@copycat.fun",
          _recipients = ["dogaruslan@gmail.com"],
          _message = "Date: Sat, 24 Jun 2023 13:43:57 +0000\\r\\n..."
        )

  """
  @spec easy_send(
          host,
          sender :: String.t(),
          recipients :: [String.t()],
          message :: iodata,
          opts :: keyword
        ) :: {:ok, receipt :: String.t()} | {:error, any}
  def easy_send(host, sender, recipients, message, opts \\ []) do
    fqdn = opts[:fqdn] || guess_fqdn_or_localhost()

    case mxlookup(host) do
      [] -> easy_send_one(host, fqdn, sender, recipients, message, opts)
      hosts -> easy_send_any(hosts, fqdn, sender, recipients, message, opts)
    end
  end

  @spec guess_fqdn_or_localhost :: String.t()
  defp guess_fqdn_or_localhost do
    case guess_fqdn() do
      {:ok, fqdn} ->
        fqdn

      {:error, reason} ->
        Logger.warning(
          "failed to guess local FQDN with reason #{inspect(reason)}," <>
            " using \"localhost\" instead"
        )

        "localhost"
    end
  end

  defp easy_send_any([host | hosts], fqdn, sender, recipients, message, opts) do
    case easy_send_one(host, fqdn, sender, recipients, message, opts) do
      {:ok, _receipt} = ok ->
        ok

      {:error, %Mua.SMTPError{code: code} = reason}
      when hosts != [] and code in [421, 450, 451, 452, 550] ->
        Logger.error("failed to send email to #{host}: " <> Exception.message(reason))
        easy_send_any(hosts, fqdn, sender, recipients, message, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp easy_send_one(host, fqdn, sender, recipients, message, opts) do
    port = opts[:port] || 25
    protocol = opts[:protocol] || :tcp
    timeout = opts[:timeout] || @default_timeout
    transport_opts = Keyword.put(opts[:transport_opts] || [], :timeout, timeout)

    with {:ok, socket, _banner} <- connect(protocol, host, port, transport_opts) do
      try do
        result =
          case ehlo(socket, fqdn, timeout) do
            {:ok, extensions} ->
              if protocol == :tcp and "STARTTLS" in extensions do
                with {:ok, socket} = ok <- starttls(socket, host, transport_opts),
                     # some servers require another EHLO after STARTTLS
                     {:ok, _} <- ehlo(socket, fqdn, timeout),
                     do: ok
              else
                {:ok, socket}
              end

            {:error, %Mua.SMTPError{code: 500}} ->
              with :ok <- helo(socket, fqdn, timeout) do
                {:ok, socket}
              end

            {:error, _reason} = error ->
              error
          end

        with {:ok, socket} <- result,
             :ok <- mail_from(socket, sender, timeout),
             :ok <- rcpt_to(socket, recipients, timeout),
             do: data(socket, message, timeout)
      after
        quit(socket, timeout)
        close(socket)
      end
    end
  end

  @doc """
  Connects to an SMTP server and receives its banner.

      {:ok, socket, _banner} = connect(:tcp, host, _port = 25)
      {:ok, socket, _banner} = connect(:ssl, host, _port = 465, verify: :verify_peer)

  """
  @spec connect(
          :tcp | :ssl,
          :inet.socket_address() | :inet.hostname() | String.t(),
          :inet.port_number(),
          opts :: keyword
        ) ::
          {:ok, socket, String.t()} | {:error, any}
  def connect(protocol, address, port, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    inet6? = Keyword.get(opts, :inet6, false)
    opts = Keyword.drop(opts, [:timeout, :inet6])
    opts = [{:mode, :binary}, {:active, false}, {:packet, :line} | opts]

    opts =
      case protocol do
        :tcp -> opts
        :ssl -> Mua.SSL.opts(address, opts)
      end

    transport_mod =
      case protocol do
        :tcp -> :gen_tcp
        :ssl = ssl -> ssl
      end

    address =
      case address do
        _ when is_binary(address) -> String.to_charlist(address)
        _ -> address
      end

    connect_result =
      if inet6? do
        case transport_mod.connect(address, port, [:inet6 | opts], timeout) do
          {:ok, _socket} = ok -> ok
          _error -> transport_mod.connect(address, port, opts, timeout)
        end
      else
        transport_mod.connect(address, port, opts, timeout)
      end

    with {:ok, socket} <- connect_result,
         {:ok, received} <- recv_all(socket, timeout) do
      case received do
        [220 | banner] ->
          {:ok, socket, IO.iodata_to_binary(banner)}

        [code | lines] ->
          # TODO need QUIT?
          case close(socket) do
            {:error, reason} ->
              Logger.warning(
                "failed to close socket on failed banner, reason: #{inspect(reason)}"
              )

            ok ->
              ok
          end

          {:error, Mua.SMTPError.exception(code: code, message: IO.iodata_to_binary(lines))}
      end
    end
  end

  @doc """
  Closes connection to the SMTP server.

      :ok = close(socket)

  """
  @spec close(socket) ::
          :ok
          | {:ok, :ssl.port()}
          | {:ok, :ssl.port(), :ssl.data()}
          | {:error, :ssl.reason()}
  def close(socket) when is_port(socket), do: :gen_tcp.close(socket)
  def close(socket), do: :ssl.close(socket)

  @doc """
  Sends `EHLO` command which provides the identification of the sender i.e. the host name,
  and receives the list of extensions the server supports.

      {:ok, _extensions = ["STARTTLS" | _rest]} = ehlo(socket, _our_hostname = "copycat.fun")

  """
  @spec ehlo(socket, String.t(), timeout) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def ehlo(socket, hostname, timeout \\ @default_timeout) when is_binary(hostname) do
    with :ok <- send(socket, ["EHLO ", hostname | "\r\n"]),
         {:ok, received} <- recv_all(socket, timeout) do
      case received do
        [250, _greeting | extensions] ->
          {:ok, extensions}

        [code | lines] ->
          {:error, Mua.SMTPError.exception(code: code, message: IO.iodata_to_binary(lines))}
      end
    end
  end

  @doc """
  Sends `HELO` command which provides the identification of the sender i.e. the host name.

      :ok = helo(socket, _our_hostname = "copycat.fun")

  """
  @spec helo(socket, String.t(), timeout) :: :ok | {:error, any}
  def helo(socket, hostname, timeout \\ @default_timeout) when is_binary(hostname) do
    with :ok <- send(socket, ["HELO ", hostname | "\r\n"]),
         {:ok, received} <- recv_all(socket, timeout) do
      case received do
        [250 | _lines] ->
          :ok

        [code | lines] ->
          {:error, Mua.SMTPError.exception(code: code, message: IO.iodata_to_binary(lines))}
      end
    end
  end

  @doc """
  Sends `STARTTLS` extension command and starts TLS session negotiation.

      {:ok, sslsocket} = starttls(socket, host, versions: [:"tlsv1.3"])

  """
  @spec starttls(:gen_tcp.socket(), host, keyword) :: {:ok, :ssl.sslsocket()} | {:error, any}
  def starttls(socket, address, opts \\ []) when is_port(socket) do
    timeout = opts[:timeout] || @default_timeout

    with :ok <- send(socket, "STARTTLS\r\n"),
         {:ok, received} <- recv_all(socket, timeout) do
      case received do
        [220 | _lines] ->
          with :ok <- :inet.setopts(socket, active: false) do
            :ssl.connect(socket, Mua.SSL.opts(address, opts), timeout)
          end

        [code | lines] ->
          {:error, Mua.SMTPError.exception(code: code, message: IO.iodata_to_binary(lines))}
      end
    end
  end

  @doc """
  Sends `AUTH` extension command and authenticates the sender.

      iex> :todo

  """
  def auth(_socket) do
    raise "TODO"
  end

  @doc """
  Sends `MAIL FROM` command that specifies the originator of the mail.

      :ok = mail_from(socket, "hey@copycat.fun")

  """
  @spec mail_from(socket, String.t(), timeout) :: :ok | {:error, any}
  def mail_from(socket, address, timeout \\ @default_timeout) do
    with :ok <- send(socket, ["MAIL FROM: ", quoteaddr(address) | "\r\n"]),
         {:ok, received} <- recv_all(socket, timeout) do
      case received do
        [250 | _lines] ->
          :ok

        [code | lines] ->
          {:error, Mua.SMTPError.exception(code: code, message: IO.iodata_to_binary(lines))}
      end
    end
  end

  @doc """
  Sends `RCPT TO` command(s) that specify the recipient(s) of the mail.

      :ok = rcpt_to(socket, ["username@hey.com", "world@hey.com"])

  """
  @spec rcpt_to(socket, [String.t()], timeout) :: :ok | {:error, any}
  def rcpt_to(socket, recipients, timeout \\ @default_timeout)

  def rcpt_to(socket, [address | addresses], timeout) do
    with :ok <- send(socket, ["RCPT TO: ", quoteaddr(address) | "\r\n"]),
         {:ok, received} <- recv_all(socket, timeout) do
      case received do
        [code | _lines] when code in [250, 251] ->
          rcpt_to(socket, addresses, timeout)

        [code | lines] ->
          {:error, Mua.SMTPError.exception(code: code, message: IO.iodata_to_binary(lines))}
      end
    end
  end

  def rcpt_to(_socket, [], _timeout), do: :ok

  @doc """
  Sends `DATA` command that specifies the beginning of the mail, and then sends the message.

      {:ok, _receipt} = data(socket, "Date: Sat, 24 Jun 2023 13:43:57 +0000\\r\\n...")

  """
  @spec data(socket, iodata, timeout) :: {:ok, receipt :: String.t()} | {:error, any}
  def data(socket, message, timeout \\ @default_timeout) do
    with :ok <- send(socket, "DATA\r\n"),
         {:ok, received} <- recv_all(socket, timeout) do
      case received do
        [354 | _lines] ->
          with :ok <- send(socket, [message | "\r\n.\r\n"]),
               {:ok, received} <- recv_all(socket, timeout) do
            case received do
              [250 | receipt] ->
                {:ok, IO.iodata_to_binary(receipt)}

              [code | lines] ->
                {:error, Mua.SMTPError.exception(code: code, message: IO.iodata_to_binary(lines))}
            end
          end

        [code | lines] ->
          {:error, Mua.SMTPError.exception(code: code, message: IO.iodata_to_binary(lines))}
      end
    end
  end

  @doc """
  Sends `VRFY` command that confirms or verifies the user name.

      {:ok, true} = vrfy(socket, "dogaruslan@gmail.com")

  """
  @spec vrfy(socket, String.t(), timeout) :: {:ok, boolean} | {:error, any}
  def vrfy(socket, address, timeout \\ @default_timeout) do
    with :ok <- send(socket, ["VRFY ", quoteaddr(address) | "\r\n"]),
         {:ok, received} <- recv_all(socket, timeout) do
      case received do
        [250 | _lines] ->
          {:ok, true}

        [code | _lines] when code in [251, 252, 551] ->
          {:ok, false}

        [code | lines] ->
          {:error, Mua.SMTPError.exception(code: code, message: IO.iodata_to_binary(lines))}
      end
    end
  end

  @doc """
  Sends `RSET` command that aborts the current mail transaction but keeps the socket open.

      :ok = rset(socket)

  """
  @spec rset(socket, timeout) :: :ok | {:error, any}
  def rset(socket, timeout \\ @default_timeout) do
    with :ok <- send(socket, "RSET\r\n"),
         {:ok, received} <- recv_all(socket, timeout) do
      case received do
        [250 | _lines] ->
          :ok

        [code | lines] ->
          {:error, Mua.SMTPError.exception(code: code, message: IO.iodata_to_binary(lines))}
      end
    end
  end

  @doc """
  Sends `NOOP` command that does nothing.

      :ok = noop(socket)

  """
  @spec noop(socket, timeout) :: :ok | {:error, Exception.t()}
  def noop(socket, timeout \\ @default_timeout) do
    with :ok <- send(socket, "NOOP\r\n"),
         {:ok, received} <- recv_all(socket, timeout) do
      case received do
        [250 | _lines] ->
          :ok

        [code | lines] ->
          {:error, Mua.SMTPError.exception(code: code, message: IO.iodata_to_binary(lines))}
      end
    end
  end

  @doc """
  Sends `QUIT` command that make the server close the connection.

      :ok = quit(socket)

  """
  @spec quit(socket, timeout) :: :ok | {:error, Exception.t()}
  def quit(socket, timeout \\ @default_timeout) do
    with :ok <- send(socket, "QUIT\r\n"),
         {:ok, received} <- recv_all(socket, timeout) do
      case received do
        [221 | _lines] ->
          :ok

        [code | lines] ->
          {:error, Mua.SMTPError.exception(code: code, message: IO.iodata_to_binary(lines))}
      end
    end
  end

  @compile inline: [send: 2]
  defp send(socket, data) when is_port(socket), do: :gen_tcp.send(socket, data)
  defp send(socket, data), do: :ssl.send(socket, data)

  @compile inline: [recv: 3]
  defp recv(socket, size, timeout) when is_port(socket), do: :gen_tcp.recv(socket, size, timeout)
  defp recv(socket, size, timeout), do: :ssl.recv(socket, size, timeout)

  defp recv_all(socket, timeout) do
    with {:ok, line} <- recv(socket, 0, timeout) do
      case line do
        <<status::3-bytes, ?\s, rest::bytes>> ->
          {:ok, [String.to_integer(status), trim_line(rest)]}

        <<status::3-bytes, ?-, rest::bytes>> ->
          recv_all_cont(socket, timeout, status, [trim_line(rest)])
      end
    end
  end

  defp recv_all_cont(socket, timeout, status, acc) do
    with {:ok, line} <- recv(socket, 0, timeout) do
      case line do
        <<^status::3-bytes, ?-, rest::bytes>> ->
          recv_all_cont(socket, timeout, status, [trim_line(rest) | acc])

        <<^status::3-bytes, ?\s, rest::bytes>> ->
          {:ok, [String.to_integer(status) | :lists.reverse([trim_line(rest) | acc])]}
      end
    end
  end

  @compile inline: [trim_line: 1]
  defp trim_line(line) do
    size = byte_size(line)

    case line do
      <<line::size(size - 2)-bytes, "\r\n">> -> line
      <<line::size(size - 1)-bytes, ?\n>> -> line
      <<line::size(size - 1)-bytes, ?\r>> -> line
    end
  end

  # TODO implement proper RFC2822
  defp quoteaddr(""), do: "<>"

  defp quoteaddr(address) when is_binary(address) do
    if String.ends_with?(address, ">") do
      address
    else
      [?<, address, ?>]
    end
  end
end
