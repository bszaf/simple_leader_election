defmodule Leader.Worker do
  @moduledoc """
  This module is responsible for electing leader node across distributed Erlang
  nodes.

  There is following constraint - Erlang nodes has to already clustered.
  """

  use GenServer
  require Logger

  @typep state :: %{
           current_leader: node(),
           election_timer: reference() | nil,
           election_replies_from: [node()],
           election: Boolean.t(),
           waiting_for_pong: Boolean.t(),
           pong_timer_ref: reference() | nil,
           timeout: Integer.t()
         }

  ###
  # API
  ###
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ###
  # GenServer callbacks
  ###

  def init(_) do
    state = %{
      current_leader: nil,
      election_timer: nil,
      election_replies_from: [],
      election: false,
      waiting_for_pong: false,
      pong_timer_ref: nil,
      timeout: 1_000
    }

    Process.send_after(self(), :keep_alive, state.timeout)
    state = maybe_start_election(state)
    {:ok, state}
  end

  #  Someone ask as if we are alive. We either:
  #   - reply with `i am the king`, if there is not bigger node among Erlang
  #     nodes (we are not checking if remote node is running worker!).
  #   - otherwise we reply `fine, thanks` and also start the election
  def handle_cast({:alive?, from}, state) do
    Logger.warn("#{node()} got alive? from #{from}")

    case am_i_the_biggest?(Node.list()) do
      true ->
        reply_iam_the_king(from)
        {:noreply, %{state | current_leader: node()}}

      false ->
        reply_fine_thanks(from)
        state = maybe_start_election(state)
        {:noreply, state}
    end
  end

  # Someone replied us `fine, thanks (I am not a boss)`. Therefore we are
  # doing following things:
  #  - reset the election timer
  #  - remember who replied
  def handle_cast(
        {:fine_thanks, node},
        %{election_replies_from: nodes, election_timer: timer, timeout: timeout} = state
      ) do
    Logger.debug("Node #{node()} got fine_thanks from #{node}")
    Process.cancel_timer(timer)
    ref = Process.send_after(self(), :election_timeout, timeout)
    replies_from = [node | nodes]
    {:noreply, %{state | election_replies_from: replies_from, election_timer: ref}}
  end

  # King replied. This is possible in two sitiuations:
  # - some greater nodes had an election, in which we were not participating.
  #   They agreed on the leader and the broadcasts its new role. Then
  #   we just update current leader on our side.
  # - we are doing an election and someone replied to us. Then, we need to
  #   reset the timer, remember who replied and update the leader.
  def handle_cast(
        {:iam_the_king, node},
        %{election_replies_from: nodes, election_timer: timer, timeout: timeout} = state
      ) do
    Logger.debug("Node #{node()} assumes #{node} is the new leader")

    state =
      case state.election do
        true ->
          Process.cancel_timer(timer)
          ref = Process.send_after(self(), :election_timeout, timeout)
          %{state | election_replies_from: [node | nodes], election_timer: ref}

        false ->
          state
      end

    {:noreply, %{state | current_leader: node}}
  end

  # Keep alive callbacks
  def handle_cast({:ping, from}, state) do
    pong(from)
    {:noreply, state}
  end

  def handle_cast(:pong, %{pong_timer_ref: ref} = state) do
    Logger.debug("keepalive")
    schedule_keepalive(state)
    Process.cancel_timer(ref)
    {:noreply, %{state | waiting_for_pong: false, pong_timer_ref: nil}}
  end

  def handle_cast(:pong, %{waiting_for_pong: false} = state) do
    Logger.warn("Received :pong after timeout")
    {:noreply, state}
  end

  # Election is finished!.
  # In previous callbacks we were tracking who is replying to us. Everyone
  # who did not reply is considered dead. Basically we just check if
  # we are the biggest among running nodes. If so - we are the boss.
  # Otherwise - someone else and we should be informed about it previously.
  #
  def handle_info(:election_timeout, %{election_replies_from: nodes} = state) do
    case am_i_the_biggest?(nodes) do
      true ->
        Logger.debug(
          "Election time out: missed responses from nodes " <>
            "#{inspect(greater_nodes(Node.list()) -- nodes)}, becoming a leader"
        )

        broadcast_iam_the_king()
        {:noreply, %{state | election_timer: nil, current_leader: node(), election: false}}

      false ->
        Logger.debug(
          "Election time out: missed responses from nodes " <>
            "#{inspect(greater_nodes(Node.list()) -- nodes)}, not becoming a leader"
        )

        {:noreply, %{state | election_timer: nil, election: false}}
    end
  end

  # Keep alive handler hit - need to start election, leader is unavailable.
  def handle_info(:pong_timeout, state) do
    Logger.debug("keepalive failed")
    state = %{state | waiting_for_pong: false, pong_timer_ref: nil}
    state = maybe_start_election(state)
    {:noreply, state}
  end

  def handle_info(:keep_alive, %{waiting_for_pong: true} = state) do
    schedule_keepalive(state)
    {:noreply, state}
  end

  # We are in this callback every `state.timeout`. Depending of the
  # status of current_leader - we decide which action should be taken.
  def handle_info(
        :keep_alive,
        %{waiting_for_pong: false, current_leader: l, timeout: t} = state
      ) do
    schedule_keepalive(state)
    myself = node()

    case l do
      nil ->
        state = maybe_start_election(state)
        {:noreply, state}

      ^myself ->
        {:noreply, state}

      _ ->
        ping(l)
        ref = Process.send_after(self(), :pong_timeout, 4 * t)
        {:noreply, %{state | waiting_for_pong: true, pong_timer_ref: ref}}
    end
  end

  ###
  # Helpers
  ###

  @spec maybe_start_election(state()) :: state()
  def maybe_start_election(%{election: true} = state) do
    state
  end

  def maybe_start_election(%{timeout: t} = state) do
    Logger.debug("#{node()} starting election")
    ref = Process.send_after(self(), :election_timeout, t)

    Node.list()
    |> greater_nodes()
    |> Enum.map(&ask_alive/1)

    %{state | election: true, current_leader: nil, election_timer: ref, election_replies_from: []}
  end

  @spec ping(node()) :: :ok
  defp ping(node), do: GenServer.cast({__MODULE__, node}, {:ping, node()})

  @spec pong(node()) :: :ok
  defp pong(node), do: GenServer.cast({__MODULE__, node}, :pong)

  @spec ask_alive(node()) :: :ok
  defp ask_alive(node) do
    Logger.debug("#{node()} asking alive to #{node}")
    GenServer.cast({__MODULE__, node}, {:alive?, node()})
  end

  @spec reply_fine_thanks(node()) :: :ok
  defp reply_fine_thanks(node) do
    Logger.debug("#{node()} replying fine_thanks to #{node}")
    GenServer.cast({__MODULE__, node}, {:fine_thanks, node()})
  end

  @spec reply_iam_the_king(node()) :: :ok
  defp reply_iam_the_king(node) do
    Logger.debug("#{node()} replying iam_the_kind to #{node}")
    GenServer.cast({__MODULE__, node}, {:iam_the_king, node()})
  end

  @spec reply_iam_the_king(node()) :: :abcast
  defp broadcast_iam_the_king() do
    Logger.debug("#{node()} broadcasting iam_the_kind to #{inspect(Node.list())}")
    GenServer.abcast(Node.list(), __MODULE__, {:iam_the_king, node()})
  end

  @spec greater_nodes([node()]) :: [node()]
  defp greater_nodes(nodes), do: Enum.filter(nodes, &(&1 > node()))

  @spec am_i_the_biggest?([node()]) :: Boolean.t()
  defp am_i_the_biggest?(nodes), do: Enum.all?(nodes, &(&1 < node()))

  @spec schedule_keepalive(state()) :: reference()
  defp schedule_keepalive(state) do
    Process.send_after(self(), :keep_alive, state.timeout)
  end
end
