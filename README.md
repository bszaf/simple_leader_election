# Leader

Simple application, which demonstrates election of leader across Erlang nodes.

## Compilation 

Just compile it with a mix:
```
$ mix compile
```

## Running

For quick testing there are 3 config files prepared in `config/` directory.
It contains configuration for each node, to avoid manual clustering of the nodes.
Files are prepared, respectively, for nodes with `shortnames`: `a`, `b` and `c`.

To start it:

```
$ iex --sname a -S mix run -c config/config_a.exs
```
As it is first node, there should be some error logs, like:
```
19:29:20.787 [warn]  Failed to connect with nodes [:b@pc75, :c@pc75]

19:29:20.787 [error] All nodes failed
```
But it is okay. Let's add another node:

```
iex --sname b -S mix run -c config/config_b.exs
```

Now we should see a few things happening:
 - nodes got clustered:
   ```
   19:30:40.094 [info]  Clustered with nodes: [:a@pc75], starting Leader
   ```
 - node a logged:
   ```
   19:30:41.098 [debug] Node a@pc75 assumes b@pc75 is the new leader
   ```
 - node b started election and won it:
   ```
   19:30:40.096 [debug] b@pc75 starting election
   19:30:41.097 [debug] Election time out: missed reponses from nodes [], becoming a leader

   19:30:41.097 [debug] b@pc75 broadcasting iam_the_kind to [:a@pc75]
   ```

> Disclaimer - why node b won? Because currently, each Worker is identified by a nodename.
> In Erlang VM, nodenames are atoms, which are comparable, what is more, they have
> some order:

```
iex(b@pc75)2> :a@pc75 > :b@pc75
false
iex(b@pc75)3> :a@pc75 < :b@pc75
true
```

Let's add third node:

```
iex --sname c -S mix  run -c config/config_c.exs
```

Now node `a` and node `b` should spot new leader:
```
19:36:02.994 [debug] Node a@pc75 assumes c@pc75 is the new leader
```
```
19:36:02.994 [debug] Node b@pc75 assumes c@pc75 is thenew leader
```

## API
As all nodes are running, we can check how the leader selection algorithm works.
Module `Leader` provides two API functions:
 - `Leader.leave_cluster/0`
 - `Leader.join_cluster/0`

By running them on different nodes, it is possible to check how the system behaves
when leader is disappearing or new node joins.
