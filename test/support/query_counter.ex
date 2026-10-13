defmodule PhoenixKitDb.QueryCounter do
  @moduledoc """
  Counts the SQL statements the test repo actually runs.

  A "this page loads its data once" claim is only worth asserting against the
  queries themselves. The telemetry handler runs in whichever process issues
  the query (the LiveView, usually), so it forwards each statement to the
  process that called `capture/1`.
  """

  @event [:phoenix_kit_db, :test, :repo, :query]

  @doc "Runs `fun` and returns `{result, statements}`, every SQL string it issued."
  def capture(fun) when is_function(fun, 0) do
    handler = {__MODULE__, make_ref()}
    owner = self()
    tag = make_ref()

    :telemetry.attach(
      handler,
      @event,
      fn _event, _measurements, metadata, _config ->
        send(owner, {tag, metadata.query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(tag, [])}
    after
      :telemetry.detach(handler)
    end
  end

  @doc "How many of `statements` contain `fragment`."
  def count(statements, fragment) do
    Enum.count(statements, &String.contains?(&1, fragment))
  end

  defp drain(tag, acc) do
    receive do
      {^tag, sql} -> drain(tag, [sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
