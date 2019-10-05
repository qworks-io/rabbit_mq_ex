defmodule MQ.Consumer do
  alias AMQP.{Basic, Channel, Connection}
  alias Core.Name
  alias MQ.ConnectionManager

  require Logger

  use GenServer

  @retry_request_channel_after_ms 2_750
  @this_module __MODULE__

  defmodule State do
    @enforce_keys [:worker_name, :module, :prefetch_count, :queue]
    defstruct channel: nil,
              consumer_tag: nil,
              worker_name: nil,
              module: nil,
              prefetch_count: nil,
              queue: nil
  end

  @spec start_link(list()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    pool_name = opts |> Keyword.fetch!(:pool_name)
    module = opts |> Keyword.fetch!(:module)
    queue = opts |> Keyword.fetch!(:queue)
    prefetch_count = opts |> Keyword.fetch!(:prefetch_count)

    worker_name = pool_name |> Name.unique_worker_name()

    Logger.metadata(worker_name: worker_name)
    Logger.info("Starting Consumer...")

    GenServer.start_link(
      @this_module,
      %State{
        worker_name: worker_name,
        module: module,
        prefetch_count: prefetch_count,
        queue: queue
      },
      name: worker_name
    )
  end

  @impl true
  def init(%State{} = initial_state) do
    request_channel()
    {:ok, initial_state}
  end

  @impl true
  def handle_cast(
        {:register_consumer, channel},
        %State{prefetch_count: prefetch_count, queue: queue} = state
      ) do
    # If anything goes wrong here, the process will die and the supervisor
    # will attempt to restart it, which is the desired behaviour.
    :ok = Basic.qos(channel, prefetch_count: prefetch_count)
    {:ok, consumer_tag} = Basic.consume(channel, queue)
    {:noreply, %{state | consumer_tag: consumer_tag}}
  end

  @impl true
  def handle_info(:request_channel, %State{worker_name: worker_name} = state) do
    Logger.metadata(worker_name: worker_name)

    case ConnectionManager.request_channel(worker_name) do
      {:ok, %Channel{} = channel} ->
        monitor_connection(channel)
        register_consumer(self(), channel)
        {:noreply, %{state | channel: channel}}

      error ->
        Logger.error(
          "Cannot retrieve channel due to #{inspect(error)}, retyring in #{
            @retry_request_channel_after_ms
          }ms."
        )

        request_channel(@retry_request_channel_after_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:basic_consume_ok, %{consumer_tag: consumer_tag}},
        %State{worker_name: worker_name} = state
      ) do
    # The only true confirmation we start consuming.
    Logger.metadata(worker_name: worker_name)
    Logger.info("Consumer successfully registered as #{consumer_tag}.")

    {:noreply, state}
  end

  @impl true
  def handle_info({:basic_deliver, payload, meta}, state) do
    spawn(fn -> consume(payload, meta, state) end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _, :process, _pid, reason}, %State{worker_name: worker_name} = state) do
    Logger.metadata(worker_name: worker_name)
    Logger.error("Connection to lost due to #{inspect(reason)}.")

    # Stop GenServer. Will be restarted by Supervisor.
    {:stop, {:connection_lost, reason}, state}
  end

  defp consume(
         payload,
         %{consumer_tag: consumer_tag, delivery_tag: delivery_tag} = meta,
         %State{
           channel: channel,
           worker_name: worker_name,
           module: processor
         }
       ) do
    Logger.metadata(
      consumer_tag: consumer_tag,
      delivery_tag: delivery_tag,
      worker_name: worker_name,
      payload: payload
    )

    Logger.debug("Begin message processing.")

    try do
      processor
      |> apply(:process_message, [payload, meta])
      |> commit(channel, meta)
    rescue
      exception ->
        Logger.error("Uncaught exception processing message; #{inspect(exception)}.")
        commit({:error, :retry_once}, channel, meta)
    end
  end

  defp commit(:ok, channel, %{delivery_tag: delivery_tag}),
    do: Basic.ack(channel, delivery_tag)

  defp commit({:error, :retry_once}, channel, %{
         delivery_tag: delivery_tag,
         redelivered: redelivered
       }),
       do: Basic.reject(channel, delivery_tag, requeue: not redelivered)

  defp commit(_, channel, %{delivery_tag: delivery_tag}),
    do: Basic.reject(channel, delivery_tag, requeue: false)

  # TODO add as required callback through behaviour?
  defp request_channel(timeout_ms \\ 0) when is_integer(timeout_ms) do
    Process.send_after(self(), :request_channel, timeout_ms)
  end

  # TODO add as required callback through behaviour?
  defp register_consumer(pid, %Channel{} = channel) when is_pid(pid) do
    GenServer.cast(pid, {:register_consumer, channel})
  end

  # We will get notified when the connection is down
  # and exit the process cleanly.
  #
  # See how we handle `{:DOWN, _, :process, _pid, reason}`.
  defp monitor_connection(%Channel{conn: %Connection{pid: pid}}) do
    Process.monitor(pid)
  end
end
