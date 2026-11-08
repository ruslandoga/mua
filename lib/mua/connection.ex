defmodule Mua.Connection do
  @moduledoc false

  defmodule Config do
    @moduledoc false

    @enforce_keys [
      :host,
      :helo,
      :port,
      :protocol,
      :connect_options,
      :tls_options,
      :auth
    ]
    defstruct @enforce_keys
  end

  @enforce_keys [:socket]
  defstruct @enforce_keys

  @type t :: %__MODULE__{socket: Mua.socket()}
  @type config :: %Config{
          host: Mua.host(),
          helo: String.t(),
          port: :inet.port_number(),
          protocol: :tcp | :ssl,
          connect_options: keyword,
          tls_options: keyword,
          auth: Mua.auth_credentials() | nil
        }

  @spec config(Mua.host(), String.t(), keyword) :: config
  def config(host, helo, opts) do
    protocol = opts[:protocol] || :tcp

    %Config{
      host: host,
      helo: helo,
      port: opts[:port] || 25,
      protocol: protocol,
      connect_options: opts[protocol] || [],
      tls_options: opts[:ssl] || [],
      auth: opts[:auth]
    }
  end

  @spec connect(config, timeout) :: {:ok, t} | Mua.error()
  def connect(%Config{} = config, timeout) do
    with {:ok, socket, _banner} <-
           Mua.connect(
             config.protocol,
             config.host,
             config.port,
             config.connect_options,
             timeout
           ) do
      try do
        case negotiate(socket, config, timeout) do
          {:ok, socket} ->
            {:ok, %__MODULE__{socket: socket}}

          {:error, error, socket} ->
            _ = Mua.close(socket)
            error
        end
      catch
        kind, reason ->
          # For STARTTLS, closing the original TCP socket also closes the
          # upgraded TLS connection if negotiation raised before it returned.
          _ = Mua.close(socket)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  @spec deliver(t, String.t(), [String.t()], iodata, timeout) ::
          {:ok, receipt :: String.t()} | Mua.error()
  def deliver(%__MODULE__{socket: socket}, sender, recipients, message, timeout) do
    with :ok <- Mua.mail_from(socket, sender, timeout),
         :ok <- many_rcpt_to(recipients, socket, timeout),
         {:ok, _receipt} = ok <- Mua.data(socket, message, timeout) do
      ok
    end
  end

  @spec reset(t, timeout) :: :ok | Mua.error()
  def reset(%__MODULE__{socket: socket}, timeout), do: Mua.rset(socket, timeout)

  @spec quit(t, timeout) :: :ok | Mua.error()
  def quit(%__MODULE__{socket: socket}, timeout), do: Mua.quit(socket, timeout)

  @spec close(t) :: :ok | Mua.error()
  def close(%__MODULE__{socket: socket}), do: Mua.close(socket)

  @spec controlling_process(t, pid) :: :ok | Mua.error()
  def controlling_process(%__MODULE__{socket: socket}, pid) when is_pid(pid) do
    result =
      if is_port(socket) do
        :gen_tcp.controlling_process(socket, pid)
      else
        :ssl.controlling_process(socket, pid)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> transport_error(reason)
    end
  end

  @spec set_mode(t, :active | :passive) :: :ok | Mua.error()
  def set_mode(%__MODULE__{socket: socket}, mode) when mode in [:active, :passive] do
    active = if mode == :active, do: :once, else: false

    result =
      if is_port(socket) do
        :inet.setopts(socket, active: active)
      else
        :ssl.setopts(socket, active: active)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> transport_error(reason)
    end
  end

  @spec owns_message?(t, term) :: boolean
  def owns_message?(%__MODULE__{socket: socket}, {kind, message_socket})
      when kind in [:tcp_closed, :ssl_closed],
      do: socket == message_socket

  def owns_message?(%__MODULE__{socket: socket}, {kind, message_socket, _data})
      when kind in [:tcp, :tcp_error, :ssl, :ssl_error],
      do: socket == message_socket

  def owns_message?(%__MODULE__{}, _message), do: false

  defp negotiate(socket, config, timeout) do
    case ehlo_or_helo(socket, config.helo, timeout) do
      {:ok, extensions} ->
        case maybe_starttls(socket, extensions, config, timeout) do
          {:ok, socket, extensions} ->
            case maybe_auth(extensions, socket, config.auth, timeout) do
              :ok -> {:ok, socket}
              {:error, _reason} = error -> {:error, error, socket}
            end

          {:error, error, socket} ->
            {:error, error, socket}
        end

      {:error, _reason} = error ->
        {:error, error, socket}
    end
  end

  defp ehlo_or_helo(socket, hostname, timeout) do
    with {:error, %Mua.SMTPError{code: 500}} <- Mua.ehlo(socket, hostname, timeout),
         :ok <- Mua.helo(socket, hostname, timeout),
         do: {:ok, []}
  end

  defp maybe_starttls(socket, extensions, config, timeout) do
    if is_port(socket) and "STARTTLS" in extensions do
      case Mua.starttls(socket, config.host, config.tls_options, timeout) do
        {:ok, tls_socket} ->
          case ehlo_or_helo(tls_socket, config.helo, timeout) do
            {:ok, extensions} -> {:ok, tls_socket, extensions}
            {:error, _reason} = error -> {:error, error, tls_socket}
          end

        {:error, _reason} = error ->
          {:error, error, socket}
      end
    else
      {:ok, socket, extensions}
    end
  end

  defp maybe_auth(_extensions, _socket, _no_auth = nil, _timeout), do: :ok

  defp maybe_auth(extensions, socket, auth_credentials, timeout) do
    method = Mua.pick_auth_method(extensions) || :plain
    Mua.auth(socket, method, auth_credentials, timeout)
  end

  defp many_rcpt_to([address | addresses], socket, timeout) do
    with :ok <- Mua.rcpt_to(socket, address, timeout),
         do: many_rcpt_to(addresses, socket, timeout)
  end

  defp many_rcpt_to([], _socket, _timeout), do: :ok

  defp transport_error(reason) do
    {:error, Mua.TransportError.exception(reason: reason)}
  end
end
