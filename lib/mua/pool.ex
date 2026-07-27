defmodule Mua.Pool do
  @moduledoc """
  A named collection of lazy SMTP connection pools.

  A separate `NimblePool` is started on first use for every SMTP destination
  and connection configuration. Connections inside those pools are also opened
  lazily, when they are first checked out.

  Add the pool to your supervision tree:

      children = [
        {Mua.Pool, name: MyMuaPool, pool_size: 10}
      ]

  Then select it when sending:

      Mua.easy_send(host, sender, recipients, message, pool: MyMuaPool)

  `:pool_size` is the maximum number of open connections for each destination.
  It defaults to `10`. Destination pools stop after five minutes without a
  delivery; configure `:pool_max_idle_time` with another timeout or
  `:infinity` to disable expiry.
  """

  use Supervisor

  alias Mua.Pool.Manager

  @default_pool_size 10
  @default_pool_timeout 5_000
  @default_pool_max_idle_time :timer.minutes(5)

  @type name :: atom

  @doc """
  Starts a named pool supervisor.
  """
  @spec start_link(keyword) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    unless is_atom(name) and not is_nil(name) do
      raise ArgumentError, "Mua.Pool :name must be a non-nil atom, got: #{inspect(name)}"
    end

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    pool_size = Keyword.get(opts, :pool_size, @default_pool_size)

    pool_max_idle_time =
      Keyword.get(opts, :pool_max_idle_time, @default_pool_max_idle_time)

    unless is_integer(pool_size) and pool_size > 0 do
      raise ArgumentError,
            "Mua.Pool :pool_size must be a positive integer, got: #{inspect(pool_size)}"
    end

    unless pool_max_idle_time == :infinity or
             (is_integer(pool_max_idle_time) and pool_max_idle_time >= 0) do
      raise ArgumentError,
            "Mua.Pool :pool_max_idle_time must be a non-negative integer or :infinity, got: " <>
              inspect(pool_max_idle_time)
    end

    pool_supervisor = pool_supervisor_name(name)

    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: pool_supervisor},
      {Manager,
       name: manager_name(name),
       pool_max_idle_time: pool_max_idle_time,
       pool_supervisor: pool_supervisor,
       pool_size: pool_size}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc false
  @spec deliver(
          name,
          Mua.Connection.config(),
          String.t(),
          [String.t()],
          iodata,
          keyword
        ) :: {:ok, String.t()} | Mua.error()
  def deliver(pool, config, sender, recipients, message, opts) when is_atom(pool) do
    timeout = Keyword.fetch!(opts, :timeout)
    pool_timeout = Keyword.get(opts, :pool_timeout, @default_pool_timeout)
    manager = manager_name(pool)

    unless Process.whereis(manager) do
      raise ArgumentError,
            "Mua.Pool #{inspect(pool)} is not running; start it under your supervision tree"
    end

    case Manager.checkout_pool(manager, config) do
      {:ok, nimble_pool, lease} ->
        try do
          NimblePool.checkout!(
            nimble_pool,
            :deliver,
            fn from, connection ->
              checkout(from, connection, config, sender, recipients, message, timeout)
            end,
            pool_timeout
          )
        catch
          :exit, {:timeout, {NimblePool, :checkout, _args}} ->
            {:error, Mua.TransportError.exception(reason: :timeout)}
        after
          Manager.checkin_pool(manager, lease)
        end

      {:error, reason} ->
        {:error, Mua.TransportError.exception(reason: {:pool_start, reason})}
    end
  end

  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  defp checkout(from, connection, config, sender, recipients, message, timeout) do
    case ensure_connected(from, connection, config, timeout) do
      {:ok, connection} ->
        result = Mua.Connection.deliver(connection, sender, recipients, message, timeout)
        {result, checkin_state(from, connection, result, timeout)}

      {:error, _reason} = error ->
        {error, {:remove, error}}
    end
  end

  defp ensure_connected(_from, %Mua.Connection{} = connection, _config, _timeout) do
    {:ok, connection}
  end

  defp ensure_connected(from, nil, config, timeout) do
    with {:ok, connection} <- Mua.Connection.connect(config, timeout) do
      :ok = NimblePool.update(from, connection)
      {:ok, connection}
    end
  end

  # DATA completion already resets a successful SMTP transaction, but RSET also
  # verifies that the session is still alive before it goes back into the pool.
  # Preserve the delivery result if this cleanup fails and evict the connection.
  defp checkin_state(from, connection, result, timeout) do
    reusable =
      case result do
        {:error, %Mua.TransportError{}} ->
          false

        {:error, %Mua.SMTPError{code: 421}} ->
          false

        _result ->
          Mua.Connection.reset(connection, timeout) == :ok
      end

    pool_pid = elem(from, 0)

    case Mua.Connection.controlling_process(connection, pool_pid) do
      :ok when reusable ->
        {:ok, connection}

      :ok ->
        {:remove, connection, :closed}

      {:error, _reason} = error ->
        _ = Mua.Connection.close(connection)
        {:remove, connection, error}
    end
  end

  @doc false
  def manager_name(name), do: :"#{name}.Manager"

  defp pool_supervisor_name(name), do: :"#{name}.PoolSupervisor"
end
