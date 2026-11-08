defmodule Mua.Pool.Manager do
  @moduledoc false

  use GenServer

  alias Mua.Pool.Worker

  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def checkout_pool(manager, config) do
    GenServer.call(manager, {:checkout_pool, config})
  end

  def checkin_pool(manager, lease) do
    GenServer.cast(manager, {:checkin_pool, lease})
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       leases: %{},
       lease_monitors: %{},
       pool_max_idle_time: Keyword.fetch!(opts, :pool_max_idle_time),
       pool_monitors: %{},
       pool_supervisor: Keyword.fetch!(opts, :pool_supervisor),
       pool_size: Keyword.fetch!(opts, :pool_size),
       pools: %{}
     }}
  end

  @impl GenServer
  def handle_call({:checkout_pool, config}, {client, _ref}, state) do
    case state.pools do
      %{^config => %{pid: pool} = entry} ->
        if Process.alive?(pool) do
          checkout(config, entry, client, state)
        else
          _entry = cancel_idle_timer(entry)
          state = %{state | pools: Map.delete(state.pools, config)}
          start_pool(config, client, state)
        end

      %{} ->
        start_pool(config, client, state)
    end
  end

  @impl GenServer
  def handle_cast({:checkin_pool, lease}, state) do
    {:noreply, release_lease(lease, state)}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case Map.pop(state.pool_monitors, monitor) do
      {{config, ^pid}, pool_monitors} ->
        pools =
          case state.pools do
            %{^config => %{pid: ^pid} = entry} ->
              _entry = cancel_idle_timer(entry)
              Map.delete(state.pools, config)

            %{} ->
              state.pools
          end

        {:noreply, %{state | pool_monitors: pool_monitors, pools: pools}}

      {nil, _pool_monitors} ->
        case Map.pop(state.lease_monitors, monitor) do
          {nil, _lease_monitors} ->
            {:noreply, state}

          {lease, lease_monitors} ->
            state = %{state | lease_monitors: lease_monitors}
            {:noreply, release_lease(lease, state, false)}
        end
    end
  end

  def handle_info({:pool_idle, config, pool, token}, state) do
    case state.pools do
      %{^config => %{active: 0, idle_token: ^token, pid: ^pool}} ->
        _ = DynamicSupervisor.terminate_child(state.pool_supervisor, pool)
        {:noreply, %{state | pools: Map.delete(state.pools, config)}}

      %{} ->
        {:noreply, state}
    end
  end

  defp checkout(config, entry, client, state) do
    lease = make_ref()
    monitor = Process.monitor(client)

    entry =
      entry
      |> cancel_idle_timer()
      |> Map.update!(:active, &(&1 + 1))

    state = %{
      state
      | lease_monitors: Map.put(state.lease_monitors, monitor, lease),
        leases: Map.put(state.leases, lease, {config, entry.pid, monitor}),
        pools: Map.put(state.pools, config, entry)
    }

    {:reply, {:ok, entry.pid, lease}, state}
  end

  defp release_lease(lease, state, demonitor? \\ true) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        state

      {{config, pool, monitor}, leases} ->
        if demonitor?, do: Process.demonitor(monitor, [:flush])

        state = %{
          state
          | lease_monitors: Map.delete(state.lease_monitors, monitor),
            leases: leases
        }

        case state.pools do
          %{^config => %{pid: ^pool} = entry} ->
            entry = %{entry | active: max(entry.active - 1, 0)}
            entry = maybe_schedule_idle(config, entry, state.pool_max_idle_time)
            %{state | pools: Map.put(state.pools, config, entry)}

          %{} ->
            state
        end
    end
  end

  defp maybe_schedule_idle(_config, %{active: active} = entry, _timeout) when active > 0 do
    cancel_idle_timer(entry)
  end

  defp maybe_schedule_idle(_config, entry, :infinity) do
    cancel_idle_timer(entry)
  end

  defp maybe_schedule_idle(config, entry, timeout) do
    entry = cancel_idle_timer(entry)
    token = make_ref()
    timer = Process.send_after(self(), {:pool_idle, config, entry.pid, token}, timeout)
    %{entry | idle_timer: timer, idle_token: token}
  end

  defp cancel_idle_timer(%{idle_timer: nil} = entry) do
    %{entry | idle_token: nil}
  end

  defp cancel_idle_timer(entry) do
    _ = Process.cancel_timer(entry.idle_timer)
    %{entry | idle_timer: nil, idle_token: nil}
  end

  defp start_pool(config, client, state) do
    opts = [config: config, pool_size: state.pool_size]

    case DynamicSupervisor.start_child(state.pool_supervisor, {Worker, opts}) do
      {:ok, pool} ->
        monitor = Process.monitor(pool)
        entry = %{active: 0, idle_timer: nil, idle_token: nil, pid: pool}

        state = %{
          state
          | pool_monitors: Map.put(state.pool_monitors, monitor, {config, pool}),
            pools: Map.put(state.pools, config, entry)
        }

        checkout(config, entry, client, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
end
