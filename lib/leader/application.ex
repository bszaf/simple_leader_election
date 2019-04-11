defmodule Leader.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  require Logger

  use Application

  def start(_type, _args) do
    res = start_supervisor()

    case Application.get_env(:leader, :nodes, []) do
      [] ->
        Logger.info("No nodes available, not starting Worker")

      nodes ->
        maybe_start_worker(nodes)
    end

    res
  end

  defp maybe_start_worker(nodes) do
    failed = connect_to(nodes)
    # if some connections failed, print warn
    failed == [] || Logger.warn("Failed to connect with nodes #{inspect(failed)}")

    case nodes -- failed do
      # could connect to any node, not starting worker
      [] ->
        Logger.error("All nodes failed")

      success ->
        Logger.info("Clustered with nodes: #{inspect(success)}, starting Leader")
    end

    Leader.join_cluster()
  end

  defp start_supervisor() do
    children = [
      {Leader.Supervisor, []}
    ]

    opts = [strategy: :one_for_one, name: Leader.Application]
    Supervisor.start_link(children, opts)
  end

  defp connect_to([]), do: []

  defp connect_to([node | t]) do
    case :net_kernel.connect_node(node) do
      true ->
        connect_to(t)

      false ->
        [node | connect_to(t)]

      ignored ->
        raise("Distributed Erlang Kernel is not started! Start node with --sname or --name")
    end
  end
end
