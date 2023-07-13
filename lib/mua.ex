defmodule Mua do
  @moduledoc """
  Minimal SMTP client.
  """

  import Kernel, except: [send: 2]
  require Logger

  @dialyzer :no_improper_lists

  @type socket :: :gen_tcp.socket() | :ssl.sslsocket()
  @type host :: :inet.socket_address() | :inet.hostname() | String.t()
  @type proto :: :tcp | :ssl

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
    fqdn =
      if fqdn = opts[:fqdn] do
        fqdn
      else
        case guess_fqdn() do
          {:ok, fqdn} ->
            fqdn

          {:error, reason} ->
            Logger.warning(
              ~s[failed to guess local FQDN with reason #{inspect(reason)}, using "localhost" instead]
            )

            "localhost"
        end
      end

    hosts =
      with [] <- mxlookup(host) do
        Logger.warning(
          "failed to lookup MX records for #{host}, will try connecting to #{host} directly"
        )

        [host]
      end

    easy_send_any(hosts, fqdn, sender, recipients, message, opts)
  end

  defp easy_send_any([host | hosts], fqdn, sender, recipients, message, opts) do
    case easy_send_one(host, fqdn, sender, recipients, message, opts) do
      {:ok, _receipt} = ok ->
        ok

      {:error, %Mua.SMTPError{code: code} = error}
      when hosts != [] and code in [421, 450, 451, 452] ->
        Logger.error("failed to send email to #{host}:\n" <> Exception.message(error))
        easy_send_any(hosts, fqdn, sender, recipients, message, opts)

      # other smtp errors are not retriable
      {:error, %Mua.SMTPError{}} = error ->
        error

      # non-smtp errors are transport errors and can be retried
      {:error, reason} when hosts != [] ->
        Logger.error("failed to send email to #{host} with reason #{inspect(reason)}")
        easy_send_any(hosts, fqdn, sender, recipients, message, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp easy_send_one(host, fqdn, sender, recipients, message, opts) do
    port = opts[:port] || 25
    proto = opts[:protocol] || :tcp
    timeout = opts[:timeout] || @default_timeout
    sock_opts = opts[:transport_opts] || []

    with {:ok, socket, _banner} <- connect(proto, host, port, sock_opts, timeout) do
      try do
        with {:ok, extensions} <- ehlo_or_helo(socket, fqdn, timeout),
             {:ok, socket} <- maybe_starttls(proto, extensions, socket, host, sock_opts, timeout),
             :ok <- maybe_auth(extensions, socket, opts, timeout),
             :ok <- mail_from(socket, sender, timeout),
             :ok <- many_rcpt_to(recipients, socket, timeout),
             {:ok, _receipt} = ok <- data(socket, message, timeout) do
          _ = quit(socket, timeout)
          ok
        end
      after
        close(socket)
      end
    end
  end

  defp many_rcpt_to([address | addresses], socket, timeout) do
    with :ok <- rcpt_to(socket, address, timeout), do: many_rcpt_to(addresses, socket, timeout)
  end

  defp many_rcpt_to([], _socket, _timeout), do: :ok

  @spec ehlo_or_helo(socket, String.t(), timeout) :: {:ok, [String.t()]} | {:error, any}
  defp ehlo_or_helo(socket, hostname, timeout) do
    with {:error, %Mua.SMTPError{code: 500}} <- ehlo(socket, hostname, timeout),
         :ok <- helo(socket, hostname, timeout),
         do: {:ok, []}
  end

  @spec maybe_starttls(proto, [String.t()], socket, String.t(), keyword, timeout) ::
          {:ok, socket} | {:error, any}
  defp maybe_starttls(protocol, extensions, socket, host, opts, timeout) do
    if protocol == :tcp and "STARTTLS" in extensions do
      starttls(socket, host, opts, timeout)
    else
      {:ok, socket}
    end
  end

  @spec maybe_auth([String.t()], socket, keyword, timeout) :: :ok | {:error, any}
  defp maybe_auth(extensions, socket, opts, timeout) do
    if method = pick_auth_method(extensions) do
      username = opts[:username]
      password = opts[:password]

      if username && password do
        auth(socket, method, opts, timeout)
      end
    end || :ok
  end

  @doc """
  Connects to an SMTP server and receives its banner.

      {:ok, socket, _banner} = connect(:tcp, host, _port = 25)
      {:ok, socket, _banner} = connect(:ssl, host, _port = 465, versions: [:"tlsv1.3"])

  """
  @spec connect(
          proto,
          :inet.socket_address() | :inet.hostname() | String.t(),
          :inet.port_number(),
          opts :: keyword,
          timeout
        ) ::
          {:ok, socket, banner :: String.t()} | {:error, any}
  def connect(protocol, address, port, opts \\ [], timeout \\ @default_timeout) do
    inet6? = Keyword.get(opts, :inet6, false)
    opts = Keyword.drop(opts, [:timeout, :inet6, :mode, :active, :packet])
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
        [220 | lines] ->
          {:ok, socket, IO.iodata_to_binary(lines)}

        [code | lines] ->
          # TODO need QUIT?
          with {:error, reason} <- close(socket) do
            Logger.warning(
              "failed to close socket on failed greeting, reason: #{inspect(reason)}"
            )
          end

          smtp_error(code, lines)
      end
    end
  end

  @doc """
  Closes connection to the SMTP server.

      :ok = close(socket)

  """
  @spec close(socket) :: :ok | {:error, any}
  def close(socket) when is_port(socket), do: :gen_tcp.close(socket)
  def close(socket), do: :ssl.close(socket)

  @doc """
  Sends `EHLO` command which provides the identification of the sender i.e. the host name,
  and receives the list of extensions the server supports.

      {:ok, _extensions = ["STARTTLS" | _rest]} = ehlo(socket, _our_hostname = "copycat.fun")

  """
  @spec ehlo(socket, String.t(), timeout) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def ehlo(socket, hostname, timeout \\ @default_timeout) when is_binary(hostname) do
    with {:ok, response} <- request(socket, ["EHLO ", hostname | "\r\n"], timeout) do
      case response do
        [250, _greeting | extensions] -> {:ok, Enum.map(extensions, &__MODULE__.trim_extension/1)}
        [code | lines] -> smtp_error(code, lines)
      end
    end
  end

  @doc false
  def trim_extension(<<_::4-bytes, line::bytes>>) do
    size = byte_size(line)

    case line do
      <<extension::size(size - 2)-bytes, "\r\n">> -> extension
      <<extension::size(size - 1)-bytes, ?\n>> -> extension
      <<extension::size(size - 1)-bytes, ?\r>> -> extension
    end
  end

  @doc """
  Sends `HELO` command which provides the identification of the sender i.e. the host name.

      :ok = helo(socket, _our_hostname = "copycat.fun")

  """
  @spec helo(socket, String.t(), timeout) :: :ok | {:error, any}
  def helo(socket, hostname, timeout \\ @default_timeout) when is_binary(hostname) do
    with {:ok, response} <- request(socket, ["HELO ", hostname | "\r\n"], timeout) do
      case response do
        [250 | _lines] -> :ok
        [code | lines] -> smtp_error(code, lines)
      end
    end
  end

  @doc """
  Sends `STARTTLS` extension command and starts TLS session negotiation.

      {:ok, sslsocket} = starttls(socket, host, versions: [:"tlsv1.3"])

  """
  @spec starttls(:gen_tcp.socket(), host, keyword, timeout) ::
          {:ok, :ssl.sslsocket()} | {:error, any}
  def starttls(socket, address, opts \\ [], timeout \\ @default_timeout) when is_port(socket) do
    with {:ok, response} <- request(socket, "STARTTLS\r\n", timeout) do
      case response do
        [220 | _lines] ->
          with :ok <- :inet.setopts(socket, active: false) do
            :ssl.connect(socket, Mua.SSL.opts(address, opts), timeout)
          end

        [code | lines] ->
          smtp_error(code, lines)
      end
    end
  end

  @type auth_method :: :login | :plain

  @doc """
  Utility function to pick a supported auth method from a list of extensions.

      {:ok, extensions} = ehlo(socket, hostname)
      maybe_method = pick_auth_method(extensions)
      true = maybe_method in [nil, :plain, :login]

  """
  @spec pick_auth_method([String.t()]) :: auth_method | nil
  def pick_auth_method(extensions) when is_list(extensions) do
    auth_extension = Enum.find(extensions, &String.starts_with?(&1, "AUTH "))

    if auth_extension do
      ["AUTH" | methods] = String.split(auth_extension)

      Enum.find_value(methods, fn method ->
        case String.upcase(method) do
          "PLAIN" -> :plain
          "LOGIN" -> :login
          _other -> nil
        end
      end)
    end
  end

  @doc """
  Sends `AUTH` extension command and authenticates the sender.

      :ok = auth(socket, :login, username: username, password: password)
      :ok = auth(socket, :plain, username: username, password: password)

  """
  @spec auth(socket, auth_method, keyword, timeout) :: :ok | {:error, any}
  def auth(socket, kind, opts \\ [], timeout \\ @default_timeout)

  def auth(socket, :login, opts, timeout) do
    username = Keyword.fetch!(opts, :username)
    password = Keyword.fetch!(opts, :password)
    username64 = [Base.encode64(username) | "\r\n"]
    password64 = [Base.encode64(password) | "\r\n"]

    with {:ok, [334, "334 VXNlcm5hbWU6\r\n"]} <- request(socket, "AUTH LOGIN\r\n", timeout),
         {:ok, [334, "334 UGFzc3dvcmQ6\r\n"]} <- request(socket, username64, timeout),
         {:ok, [235 | _lines]} <- request(socket, password64, timeout) do
      :ok
    else
      {:ok, [code | lines]} -> smtp_error(code, lines)
      {:error, _reason} = error -> error
    end
  end

  def auth(socket, :plain, opts, timeout) do
    username = Keyword.fetch!(opts, :username)
    password = Keyword.fetch!(opts, :password)

    cmd = ["AUTH PLAIN ", Base.encode64(<<0, username::bytes, 0, password::bytes>>) | "\r\n"]

    with {:ok, response} <- request(socket, cmd, timeout) do
      case response do
        [235 | _lines] -> :ok
        [code | lines] -> smtp_error(code, lines)
      end
    end
  end

  @doc """
  Sends `MAIL FROM` command that specifies the originator of the mail.

      :ok = mail_from(socket, "hey@copycat.fun")

  """
  @spec mail_from(socket, String.t(), timeout) :: :ok | {:error, any}
  def mail_from(socket, address, timeout \\ @default_timeout) do
    with {:ok, response} <- request(socket, ["MAIL FROM: ", quoteaddr(address) | "\r\n"], timeout) do
      case response do
        [250 | _lines] -> :ok
        [code | lines] -> smtp_error(code, lines)
      end
    end
  end

  @doc """
  Sends `RCPT TO` command that specify the recipient of the mail.

      :ok = rcpt_to(socket, "world@hey.com")

  """
  @spec rcpt_to(socket, String.t(), timeout) :: :ok | {:error, any}
  def rcpt_to(socket, address, timeout \\ @default_timeout) do
    with {:ok, response} <- request(socket, ["RCPT TO: ", quoteaddr(address) | "\r\n"], timeout) do
      case response do
        [code | _lines] when code in [250, 251] -> :ok
        [code | lines] -> smtp_error(code, lines)
      end
    end
  end

  @doc """
  Sends `DATA` command that specifies the beginning of the mail, and then sends the message.

      {:ok, _receipt} = data(socket, "Date: Sat, 24 Jun 2023 13:43:57 +0000\\r\\n...")

  """
  @spec data(socket, iodata, timeout) :: {:ok, receipt :: String.t()} | {:error, any}
  def data(socket, message, timeout \\ @default_timeout) do
    with {:ok, response} <- request(socket, "DATA\r\n", timeout) do
      case response do
        [354 | _lines] ->
          with {:ok, response} <- request(socket, [message | "\r\n.\r\n"], timeout) do
            case response do
              [250 | lines] -> {:ok, IO.iodata_to_binary(lines)}
              [code | lines] -> smtp_error(code, lines)
            end
          end

        [code | lines] ->
          smtp_error(code, lines)
      end
    end
  end

  @doc """
  Sends `VRFY` command that confirms or verifies the user name.

      {:ok, true} = vrfy(socket, "dogaruslan@gmail.com")

  """
  @spec vrfy(socket, String.t(), timeout) :: {:ok, boolean} | {:error, any}
  def vrfy(socket, address, timeout \\ @default_timeout) do
    with {:ok, response} <- request(socket, ["VRFY ", quoteaddr(address) | "\r\n"], timeout) do
      case response do
        [250 | _lines] -> {:ok, true}
        [code | _lines] when code in [251, 252, 551] -> {:ok, false}
        [code | lines] -> smtp_error(code, lines)
      end
    end
  end

  @doc """
  Sends `RSET` command that aborts the current mail transaction but keeps the socket open.

      :ok = rset(socket)

  """
  @spec rset(socket, timeout) :: :ok | {:error, any}
  def rset(socket, timeout \\ @default_timeout) do
    with {:ok, response} <- request(socket, "RSET\r\n", timeout) do
      case response do
        [250 | _lines] -> :ok
        [code | lines] -> smtp_error(code, lines)
      end
    end
  end

  @doc """
  Sends `NOOP` command that does nothing.

      :ok = noop(socket)

  """
  @spec noop(socket, timeout) :: :ok | {:error, any}
  def noop(socket, timeout \\ @default_timeout) do
    with {:ok, response} <- request(socket, "NOOP\r\n", timeout) do
      case response do
        [250 | _lines] -> :ok
        [code | lines] -> smtp_error(code, lines)
      end
    end
  end

  @doc """
  Sends `QUIT` command that make the server close the connection.

      :ok = quit(socket)

  """
  @spec quit(socket, timeout) :: :ok | {:error, Exception.t()}
  def quit(socket, timeout \\ @default_timeout) do
    with {:ok, response} <- request(socket, "QUIT\r\n", timeout) do
      case response do
        [221 | _lines] -> :ok
        [code | lines] -> smtp_error(code, lines)
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
        <<status::3-bytes, ?\s, _::bytes>> = line ->
          {:ok, [String.to_integer(status), line]}

        <<status::3-bytes, ?-, _::bytes>> = line ->
          recv_all_cont(socket, timeout, status, [line])
      end
    end
  end

  defp recv_all_cont(socket, timeout, status, acc) do
    with {:ok, line} <- recv(socket, 0, timeout) do
      case line do
        <<^status::3-bytes, ?-, _::bytes>> = line ->
          recv_all_cont(socket, timeout, status, [line | acc])

        <<^status::3-bytes, ?\s, _::bytes>> = line ->
          {:ok, [String.to_integer(status) | :lists.reverse([line | acc])]}
      end
    end
  end

  @compile inline: [request: 3]
  defp request(socket, data, timeout) do
    with :ok <- send(socket, data), do: recv_all(socket, timeout)
  end

  @compile inline: [smtp_error: 2]
  defp smtp_error(code, lines) do
    {:error, Mua.SMTPError.exception(code: code, lines: lines)}
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
