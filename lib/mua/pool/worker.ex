defmodule Mua.Pool.Worker do
  @moduledoc false

  @behaviour NimblePool

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    pool_size = Keyword.fetch!(opts, :pool_size)

    NimblePool.start_link(
      worker: {__MODULE__, config},
      pool_size: pool_size,
      lazy: true
    )
  end

  @impl NimblePool
  def init_worker(config), do: {:ok, nil, config}

  @impl NimblePool
  def handle_checkout(:deliver, _from, nil, config) do
    {:ok, nil, nil, config}
  end

  def handle_checkout(:deliver, {client, _ref}, connection, config) do
    with :ok <- Mua.Connection.set_mode(connection, :passive),
         :ok <- Mua.Connection.controlling_process(connection, client) do
      {:ok, connection, connection, config}
    else
      {:error, reason} -> {:remove, reason, config}
    end
  end

  @impl NimblePool
  def handle_update(connection, _old_connection, config) do
    {:ok, connection, config}
  end

  @impl NimblePool
  def handle_checkin({:ok, connection}, _from, _old_connection, config) do
    case Mua.Connection.set_mode(connection, :active) do
      :ok -> {:ok, connection, config}
      {:error, reason} -> {:remove, reason, config}
    end
  end

  def handle_checkin({:remove, _connection, reason}, _from, _old_connection, config) do
    {:remove, reason, config}
  end

  def handle_checkin({:remove, reason}, _from, _old_connection, config) do
    {:remove, reason, config}
  end

  @impl NimblePool
  def handle_info(_message, nil), do: {:ok, nil}

  def handle_info(message, connection) do
    if Mua.Connection.owns_message?(connection, message) do
      {:remove, :closed}
    else
      {:ok, connection}
    end
  end

  @impl NimblePool
  def terminate_worker(_reason, nil, config), do: {:ok, config}

  def terminate_worker(_reason, connection, config) do
    _ = Mua.Connection.close(connection)
    {:ok, config}
  end
end
