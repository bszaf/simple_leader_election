defmodule Leader do
  @moduledoc """
  Documentation for Leader.
  """

  @doc """
  Hello world.

  ## Examples

      iex> Leader.hello()
      :world

  """
  def join_cluster() do
    DynamicSupervisor.start_child(Leader.Supervisor, {Leader.Worker, %{}})
  end

  def leave_cluster() do
    DynamicSupervisor.terminate_child(Leader.Supervisor, :erlang.whereis(Leader.Worker))
  end
end
