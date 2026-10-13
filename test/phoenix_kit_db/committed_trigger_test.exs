defmodule PhoenixKitDb.CommittedTriggerTest do
  @moduledoc """
  The two things the SQL sandbox cannot show, because both need a second
  connection and a real commit:

    * a write firing the plpgsql function, the NOTIFY reaching the Listener's
      own connection, and the Listener broadcasting it;
    * trigger DDL meeting a lock another transaction holds.

  The test table is created and dropped on an unboxed connection, so it is
  really there for the lock holder and the Listener. Everything else stays in
  the sandbox and is rolled back.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import PhoenixKitDb.LiveCase, only: [fake_scope: 0, put_test_scope: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitDb.Fixtures
  alias PhoenixKitDb.Listener
  alias PhoenixKitDb.PubSub
  alias PhoenixKitDb.QueryCounter
  alias PhoenixKitDb.Test.Repo, as: TestRepo

  @moduletag :integration
  @endpoint PhoenixKitDb.Test.Endpoint

  @table "pk_db_committed"

  setup context do
    # Unboxed work first: once a shared sandbox owner exists, every process
    # is routed to its connection. A trigger a test needs COMMITTED is
    # installed here too: installed inside the sandbox, the sandbox's own
    # open transaction would hold the table lock the test wants to contend.
    Fixtures.unboxed(fn ->
      Fixtures.sql!("DROP TABLE IF EXISTS #{@table}")
      Fixtures.sql!("CREATE TABLE #{@table} (id bigserial PRIMARY KEY, label text)")
      Fixtures.sql!("INSERT INTO #{@table} (label) VALUES ('first')")

      if context[:committed_trigger] do
        :ok = PhoenixKitDb.ensure_trigger("public", @table)
      end
    end)

    on_exit(fn ->
      Fixtures.unboxed(fn ->
        Fixtures.sql!("DROP TABLE IF EXISTS #{@table}")
        Fixtures.sql!("DROP FUNCTION IF EXISTS phoenix_kit_notify_table_change()")
      end)
    end)

    {:ok, writer} =
      TestRepo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :database])
      |> Postgrex.start_link()

    %{writer: writer}
  end

  defp start_sandbox(_context) do
    owner = Sandbox.start_owner!(TestRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  # Holds a lock that conflicts with trigger DDL, the way any open transaction
  # that has written to the table does. Returns the function that releases it.
  defp hold_write_lock(writer) do
    test = self()

    task =
      Task.async(fn ->
        Postgrex.transaction(
          writer,
          fn conn ->
            Postgrex.query!(conn, "LOCK TABLE #{@table} IN ROW EXCLUSIVE MODE", [])
            send(test, :locked)

            receive do
              :release -> :ok
            end
          end,
          timeout: :infinity
        )
      end)

    assert_receive :locked, 5_000

    fn ->
      send(task.pid, :release)
      Task.await(task)
    end
  end

  defp with_short_lock_timeout(_context) do
    Application.put_env(:phoenix_kit_db, :ddl_lock_timeout_ms, 150)
    on_exit(fn -> Application.delete_env(:phoenix_kit_db, :ddl_lock_timeout_ms) end)
    :ok
  end

  describe "a committed write" do
    test "notification byte limits never abort writes and preserve the table event", %{
      writer: writer
    } do
      Fixtures.unboxed(fn ->
        Fixtures.sql!("DROP TABLE #{@table}")
        Fixtures.sql!("CREATE TABLE #{@table} (id text, label text)")
        assert :ok = PhoenixKitDb.ensure_trigger("public", @table)
      end)

      notifications = start_supervised!({Postgrex.Notifications, TestRepo.config()})
      {:ok, ref} = Postgrex.Notifications.listen(notifications, PhoenixKitDb.notify_channel())
      prefix = "public.#{@table}:INSERT:"

      for id <- [
            "user:42:web",
            String.duplicate("x", 7999 - byte_size(prefix)),
            String.duplicate("x", 8000 - byte_size(prefix)),
            String.duplicate("界", 2700)
          ] do
        assert {:ok, _} = Postgrex.query(writer, "INSERT INTO #{@table} VALUES ($1, 'ok')", [id])
        expected = if byte_size(prefix <> id) < 8000, do: prefix <> id, else: prefix

        assert_receive {:notification, ^notifications, ^ref, "phoenix_kit_db_changes", ^expected},
                       1000
      end

      assert {:ok, _} = Postgrex.query(writer, "UPDATE #{@table} SET label = 'updated'", [])

      assert_receive {:notification, ^notifications, ^ref, "phoenix_kit_db_changes",
                      "public.pk_db_committed:UPDATE:"},
                     1000

      assert {:ok, _} = Postgrex.query(writer, "DELETE FROM #{@table}", [])

      assert_receive {:notification, ^notifications, ^ref, "phoenix_kit_db_changes",
                      "public.pk_db_committed:DELETE:"},
                     1000
    end

    test "concurrent installation replaces the function once and all callers succeed" do
      {results, statements} =
        QueryCounter.capture(fn ->
          1..8
          |> Task.async_stream(
            fn _ -> Fixtures.unboxed(fn -> PhoenixKitDb.ensure_notify_function() end) end,
            max_concurrency: 8,
            timeout: 10_000
          )
          |> Enum.to_list()
        end)

      assert results == List.duplicate({:ok, :ok}, 8)
      assert QueryCounter.count(statements, "CREATE OR REPLACE FUNCTION") == 1
    end

    @tag :committed_trigger
    test "fires a NOTIFY that the Listener broadcasts to subscribers", %{writer: writer} do
      start_supervised!(Listener)
      PubSub.subscribe(PubSub.topic_table("public", @table))
      PubSub.subscribe(PubSub.topic_all())

      # The Listener connects on its own schedule, so writes are repeated
      # until one is heard.
      id =
        Enum.find_value(1..40, fn _attempt ->
          %{rows: [[id]]} =
            Postgrex.query!(writer, "INSERT INTO #{@table} (label) VALUES ('x') RETURNING id", [])

          text = Integer.to_string(id)

          receive do
            {:table_changed, "public", @table, "INSERT", ^text} -> id
          after
            250 -> nil
          end
        end)

      assert is_integer(id), "no NOTIFY arrived for any of the inserts"
      text = Integer.to_string(id)

      # Both topics carry it.
      assert_receive {:table_changed, "public", @table, "INSERT", ^text}, 1_000

      Postgrex.query!(writer, "UPDATE #{@table} SET label = 'y' WHERE id = $1", [id])
      assert_receive {:table_changed, "public", @table, "UPDATE", ^text}, 2_000
      assert_receive {:table_changed, "public", @table, "UPDATE", ^text}, 2_000

      Postgrex.query!(writer, "DELETE FROM #{@table} WHERE id = $1", [id])
      assert_receive {:table_changed, "public", @table, "DELETE", ^text}, 2_000
      assert_receive {:table_changed, "public", @table, "DELETE", ^text}, 2_000
    end

    @tag :committed_trigger
    test "is silent once the trigger is removed", %{writer: writer} do
      Fixtures.unboxed(fn -> assert :ok = PhoenixKitDb.remove_all_triggers() end)

      start_supervised!(Listener)
      PubSub.subscribe(PubSub.topic_all())

      for _ <- 1..5 do
        Postgrex.query!(writer, "INSERT INTO #{@table} (label) VALUES ('quiet')", [])
      end

      refute_receive {:table_changed, "public", @table, _, _}, 700
    end
  end

  describe "trigger DDL behind a held lock" do
    setup [:with_short_lock_timeout, :start_sandbox]

    test "notify-function upgrades give up under an advisory lock and recover", %{writer: writer} do
      test_pid = self()

      holder =
        Task.async(fn ->
          Postgrex.transaction(writer, fn conn ->
            Postgrex.query!(conn, "SELECT pg_advisory_xact_lock(hashtext($1)::bigint)", [
              "phoenix_kit_notify_table_change"
            ])

            send(test_pid, :function_locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :function_locked, 5_000
      started = System.monotonic_time(:millisecond)
      assert {:error, :lock_timeout} = PhoenixKitDb.ensure_notify_function()
      assert System.monotonic_time(:millisecond) - started < 2_000
      send(holder.pid, :release)
      Task.await(holder)
      assert :ok = PhoenixKitDb.ensure_notify_function()
    end

    test "ensure_trigger/2 gives up with :lock_timeout and works once the lock is gone",
         %{writer: writer} do
      release = hold_write_lock(writer)

      started = System.monotonic_time(:millisecond)
      assert {:error, :lock_timeout} = PhoenixKitDb.ensure_trigger("public", @table)
      assert System.monotonic_time(:millisecond) - started < 2_000
      refute PhoenixKitDb.has_trigger?("public", @table)

      release.()

      assert :ok = PhoenixKitDb.ensure_trigger("public", @table)
      assert PhoenixKitDb.has_trigger?("public", @table)
    end

    test "the Show page still loads and says live updates are unavailable", %{writer: writer} do
      release = hold_write_lock(writer)
      conn = build_conn() |> Plug.Test.init_test_session(%{}) |> put_test_scope(fake_scope())

      {{:ok, view, html}, log} =
        with_log(fn -> live(conn, "/en/admin/db/public/#{@table}") end)

      assert has_element?(view, "#db-live-updates-unavailable")
      assert html =~ "Live updates are not available for this table right now"
      # The rows are there all the same.
      assert has_element?(view, "#table-container td", "first")
      assert log =~ "ensure_trigger"

      release.()
    end

    @tag :committed_trigger
    test "disable_system/0 still disables when a trigger cannot be dropped", %{writer: writer} do
      assert PhoenixKitDb.has_trigger?("public", @table)
      assert {:ok, _} = PhoenixKitDb.enable_system()
      release = hold_write_lock(writer)

      {result, log} = with_log(fn -> PhoenixKitDb.disable_system() end)

      assert {:ok, _} = result
      refute PhoenixKitDb.enabled?()
      assert log =~ "could not remove the trigger on public.#{@table}"
      assert PhoenixKitDb.has_trigger?("public", @table)

      assert log =~ "run PhoenixKitDb.remove_all_triggers() again"

      # Asked directly, it names the table it could not clean.
      {again, _log} = with_log(fn -> PhoenixKitDb.remove_all_triggers() end)
      assert {:error, [{"public", @table}]} = again

      release.()

      # Nothing remembers the failure: a second disable finds the leftover in
      # the catalog and removes it.
      assert {:ok, _} = PhoenixKitDb.disable_system()
      refute PhoenixKitDb.has_trigger?("public", @table)
      assert :ok = PhoenixKitDb.remove_all_triggers()
    end
  end

  describe "the Show page without contention" do
    setup [:start_sandbox]

    test "shows no live-updates note" do
      conn = build_conn() |> Plug.Test.init_test_session(%{}) |> put_test_scope(fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/db/public/#{@table}")

      refute has_element?(view, "#db-live-updates-unavailable")
      assert PhoenixKitDb.has_trigger?("public", @table)
    end
  end
end
