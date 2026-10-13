defmodule PhoenixKitDb.ListenerTest do
  @moduledoc """
  Pinning tests for the `Postgrex.Notifications` payload parser and
  PubSub broadcast fan-out.

  These tests do NOT require a real Postgres connection — `Listener.init/1`
  returns `{:ok, %{conn: nil}}` when no host repo is configured, which is
  fine for exercising `handle_info({:notification, …}, state)` directly
  via `send/2`.
  """

  use ExUnit.Case, async: false

  alias PhoenixKitDb.Listener
  alias PhoenixKitDb.PubSub

  setup do
    pid = start_supervised!(Listener)
    %{pid: pid}
  end

  describe "valid notification payload" do
    test "broadcasts to both topic_table/2 and topic_all/0", %{pid: pid} do
      PubSub.subscribe(PubSub.topic_table("public", "phoenix_kit_settings"))
      PubSub.subscribe(PubSub.topic_all())

      send(
        pid,
        {:notification, self(), make_ref(), "phoenix_kit_db_changes",
         "public.phoenix_kit_settings:UPDATE:42"}
      )

      # Each subscriber receives one copy.
      assert_receive {:table_changed, "public", "phoenix_kit_settings", "UPDATE", "42"}, 500
      assert_receive {:table_changed, "public", "phoenix_kit_settings", "UPDATE", "42"}, 500
    end

    test "empty row_id normalises to nil", %{pid: pid} do
      PubSub.subscribe(PubSub.topic_all())

      send(
        pid,
        {:notification, self(), make_ref(), "phoenix_kit_db_changes",
         "public.no_pk_table:INSERT:"}
      )

      assert_receive {:table_changed, "public", "no_pk_table", "INSERT", nil}, 500
    end

    test "handles INSERT, UPDATE, DELETE operations", %{pid: pid} do
      PubSub.subscribe(PubSub.topic_all())

      for op <- ["INSERT", "UPDATE", "DELETE"] do
        send(
          pid,
          {:notification, self(), make_ref(), "phoenix_kit_db_changes", "public.users:#{op}:99"}
        )

        assert_receive {:table_changed, "public", "users", ^op, "99"}, 500
      end
    end

    test "schemas containing dots (uncommon but legal) split on first dot only", %{pid: pid} do
      # `String.split(_, ".", parts: 2)` keeps the rest joined — so a
      # table name like "weird.dotted" still parses as schema=public,
      # table="weird.dotted". Pin this so a future refactor doesn't
      # silently break the parse.
      PubSub.subscribe(PubSub.topic_all())

      send(
        pid,
        {:notification, self(), make_ref(), "phoenix_kit_db_changes",
         "public.weird.name:INSERT:1"}
      )

      assert_receive {:table_changed, "public", "weird.name", "INSERT", "1"}, 500
    end
  end

  describe "malformed notification payloads" do
    test "swallows payload with too few colons (no operation)", %{pid: pid} do
      PubSub.subscribe(PubSub.topic_all())

      send(pid, {:notification, self(), make_ref(), "phoenix_kit_db_changes", "public.users"})

      refute_receive {:table_changed, _, _, _, _}, 200
    end

    test "swallows empty payload", %{pid: pid} do
      PubSub.subscribe(PubSub.topic_all())

      send(pid, {:notification, self(), make_ref(), "phoenix_kit_db_changes", ""})

      refute_receive {:table_changed, _, _, _, _}, 200
    end

    test "swallows payload with no schema separator", %{pid: pid} do
      PubSub.subscribe(PubSub.topic_all())

      send(
        pid,
        {:notification, self(), make_ref(), "phoenix_kit_db_changes", "noschema:UPDATE:1"}
      )

      refute_receive {:table_changed, _, _, _, _}, 200
    end
  end

  describe "a row id with colons of its own" do
    test "is broadcast whole instead of dropping the event", %{pid: pid} do
      PubSub.subscribe(PubSub.topic_all())

      send(
        pid,
        {:notification, self(), make_ref(), "phoenix_kit_db_changes",
         "public.sessions:UPDATE:user:42:web"}
      )

      assert_receive {:table_changed, "public", "sessions", "UPDATE", "user:42:web"}, 500
    end
  end

  describe "unrelated messages" do
    test "the Listener keeps broadcasting after messages it does not know", %{pid: pid} do
      PubSub.subscribe(PubSub.topic_all())

      send(pid, :some_unrelated_message)
      send(pid, {:tuple, :that, :doesnt, :match})

      send(
        pid,
        {:notification, self(), make_ref(), "phoenix_kit_db_changes", "public.users:INSERT:7"}
      )

      assert_receive {:table_changed, "public", "users", "INSERT", "7"}, 500
    end
  end

  describe "logging" do
    test "a notification is not logged at :info or above", %{pid: pid} do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      payload = "public.users:INSERT:7"
      message = {:notification, self(), make_ref(), "phoenix_kit_db_changes", payload}

      deliver = fn ->
        send(pid, message)
        # A call is answered after the notification before it is handled.
        :sys.get_state(pid)
      end

      assert ExUnit.CaptureLog.capture_log([level: :debug], deliver) =~
               "public.users - INSERT"

      refute ExUnit.CaptureLog.capture_log([level: :info], deliver) =~ "public.users - INSERT"
    end
  end

  describe "connection_config/1" do
    test "passes through everything that decides where and how the repo connects" do
      repo_config = [
        hostname: "db.internal",
        port: 6543,
        database: "app",
        username: "app",
        password: "pw",
        ssl: true,
        ssl_opts: [verify: :verify_none],
        socket_options: [:inet6],
        parameters: [application_name: "app", search_path: "tenant"],
        pool: Ecto.Adapters.SQL.Sandbox,
        pool_size: 10
      ]

      config = Listener.connection_config(repo_config)

      assert config[:socket_options] == [:inet6]
      assert config[:parameters] == [application_name: "app", search_path: "tenant"]
      assert config[:hostname] == "db.internal"
      assert config[:port] == 6543
      assert config[:ssl] == true
      assert config[:ssl_opts] == [verify: :verify_none]
      assert config[:auto_reconnect] == true
      refute Keyword.has_key?(config, :pool)
      refute Keyword.has_key?(config, :pool_size)
    end

    test "fills in the host and port a socket-less config leaves out" do
      config = Listener.connection_config(database: "app")

      assert config[:hostname] == "localhost"
      assert config[:port] == 5432
      refute Keyword.has_key?(config, :socket_options)
    end
  end

  describe "topic helpers" do
    test "topic_all returns the workspace-wide channel" do
      assert PubSub.topic_all() == "phoenix_kit_db:all"
    end

    test "topic_table embeds schema.table" do
      assert PubSub.topic_table("public", "users") == "phoenix_kit_db:public.users"

      # Each schema/table pair is a distinct topic — pin so a refactor
      # doesn't accidentally collapse two tables onto the same topic.
      refute PubSub.topic_table("public", "a") == PubSub.topic_table("public", "b")
      refute PubSub.topic_table("public", "x") == PubSub.topic_table("private", "x")
    end
  end
end
