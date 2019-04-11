use Mix.Config

others = ["a", "c"]
{:ok, hostname} = :inet.gethostname()
hostname = to_string(hostname)

config :leader,
  nodes:
    others
    |> Enum.map(&(&1 <> "@" <> hostname))
    |> Enum.map(&String.to_atom/1)
