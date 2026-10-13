defmodule PhoenixKitDb.TriggersTest do
  @moduledoc """
  The trigger DDL against the real test database: install, detect, list and
  remove, including names Postgres truncates and `disable_system/0`'s cleanup.

  `async: false` because `disable_system/0` writes the process-wide settings
  cache.
  """
  use PhoenixKitDb.DataCase, async: false

  alias PhoenixKitDb.Fixtures
  alias PhoenixKitDb.QueryCounter

  @function "phoenix_kit_notify_table_change"
  @prefix "phoenix_kit_db_change_"

  # 60 characters: with the prefix and schema the trigger name is far past
  # Postgres' 63-byte identifier limit.
  @long_a "pk_db_long_" <> String.duplicate("a", 48) <> "1"
  @long_b "pk_db_long_" <> String.duplicate("a", 48) <> "2"

  defp create_table(name), do: Fixtures.sql!("CREATE TABLE #{name} (id int PRIMARY KEY, v text)")

  # Every user trigger on a table, as `{name, function}`.
  defp triggers_on(table) do
    %{rows: rows} =
      Fixtures.sql!(
        """
        SELECT t.tgname::text, p.proname::text
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE NOT t.tgisinternal AND c.relname = $1
        ORDER BY t.tgname
        """,
        [table]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  describe "ensure_trigger/2" do
    test "installs the function and one trigger, and the table then reports it" do
      create_table("pk_db_trg")

      refute PhoenixKitDb.has_trigger?("public", "pk_db_trg")
      refute {"public", "pk_db_trg"} in PhoenixKitDb.list_triggered_tables()

      assert :ok = PhoenixKitDb.ensure_trigger("public", "pk_db_trg")

      assert triggers_on("pk_db_trg") == [{@prefix <> "public_pk_db_trg", @function}]
      assert PhoenixKitDb.has_trigger?("public", "pk_db_trg")
      assert {"public", "pk_db_trg"} in PhoenixKitDb.list_triggered_tables()
    end

    test "a second call finds the trigger and issues no CREATE TRIGGER" do
      create_table("pk_db_trg")
      assert :ok = PhoenixKitDb.ensure_trigger("public", "pk_db_trg")

      {result, statements} =
        QueryCounter.capture(fn -> PhoenixKitDb.ensure_trigger("public", "pk_db_trg") end)

      assert result == :ok
      assert QueryCounter.count(statements, "CREATE TRIGGER") == 0
      assert QueryCounter.count(statements, "CREATE OR REPLACE FUNCTION") == 0
      assert QueryCounter.count(statements, "pg_advisory_xact_lock") == 0
      assert length(triggers_on("pk_db_trg")) == 1
    end

    test "the DDL runs under a lock timeout" do
      create_table("pk_db_trg")

      {result, statements} =
        QueryCounter.capture(fn -> PhoenixKitDb.ensure_trigger("public", "pk_db_trg") end)

      assert result == :ok

      create_at = Enum.find_index(statements, &(&1 =~ "CREATE TRIGGER"))
      timeout_at = Enum.find_index(statements, &(&1 =~ "SET LOCAL lock_timeout"))

      assert is_integer(create_at) and is_integer(timeout_at)
      assert timeout_at < create_at
    end

    test "a table that does not exist is an error tuple, not a raise" do
      assert {:error, %Postgrex.Error{}} = PhoenixKitDb.ensure_trigger("public", "pk_db_absent")
      refute PhoenixKitDb.has_trigger?("public", "pk_db_absent")
    end
  end

  test "a stale notify function is updated without installing a settings trigger" do
    Fixtures.sql!(
      "CREATE FUNCTION #{@function}() RETURNS trigger AS $$ BEGIN RETURN NEW; END; $$ LANGUAGE plpgsql"
    )

    assert :ok = PhoenixKitDb.ensure_notify_function()
    assert PhoenixKitDb.list_triggered_tables() == []

    assert %{rows: [[body]]} =
             Fixtures.sql!(
               "SELECT prosrc FROM pg_proc WHERE oid = '#{@function}()'::regprocedure"
             )

    assert body =~ "octet_length"
  end

  describe "trigger names past the 63-byte identifier limit" do
    test "the stored name fits, is recognised, and a second call creates nothing" do
      create_table(@long_a)

      assert :ok = PhoenixKitDb.ensure_trigger("public", @long_a)
      assert [{name, @function}] = triggers_on(@long_a)

      assert byte_size(name) == 63
      assert String.starts_with?(name, @prefix)
      assert PhoenixKitDb.has_trigger?("public", @long_a)

      {result, statements} =
        QueryCounter.capture(fn -> PhoenixKitDb.ensure_trigger("public", @long_a) end)

      assert result == :ok
      assert QueryCounter.count(statements, "CREATE TRIGGER") == 0
      assert triggers_on(@long_a) == [{name, @function}]
    end

    test "two long names sharing their first 63 bytes get different trigger names" do
      create_table(@long_a)
      create_table(@long_b)

      assert :ok = PhoenixKitDb.ensure_trigger("public", @long_a)
      assert :ok = PhoenixKitDb.ensure_trigger("public", @long_b)

      [{name_a, _}] = triggers_on(@long_a)
      [{name_b, _}] = triggers_on(@long_b)

      assert name_a != name_b
      assert binary_part(name_a, 0, 54) == binary_part(name_b, 0, 54)
    end

    test "a trigger created under the plain truncated name is recognised and removed" do
      create_table("pk_db_trg")
      create_table(@long_a)
      # Installs the notification function the hand-made trigger calls.
      assert :ok = PhoenixKitDb.ensure_trigger("public", "pk_db_trg")

      legacy = binary_part(@prefix <> "public_" <> @long_a, 0, 63)

      Fixtures.sql!("""
      CREATE TRIGGER #{legacy} AFTER INSERT OR UPDATE OR DELETE ON #{@long_a}
      FOR EACH ROW EXECUTE FUNCTION #{@function}()
      """)

      assert PhoenixKitDb.has_trigger?("public", @long_a)
      assert {"public", @long_a} in PhoenixKitDb.list_triggered_tables()

      # Recognised, so no second trigger is stacked on the table.
      assert :ok = PhoenixKitDb.ensure_trigger("public", @long_a)
      assert triggers_on(@long_a) == [{legacy, @function}]

      assert :ok = PhoenixKitDb.remove_trigger("public", @long_a)
      assert triggers_on(@long_a) == []
      refute PhoenixKitDb.has_trigger?("public", @long_a)
    end
  end

  describe "what counts as this module's trigger" do
    setup do
      create_table("pk_db_trg")
      create_table("pk_db_foreign")
      assert :ok = PhoenixKitDb.ensure_trigger("public", "pk_db_trg")

      Fixtures.sql!("""
      CREATE FUNCTION pk_db_other_fn() RETURNS trigger AS $$
      BEGIN RETURN NEW; END; $$ LANGUAGE plpgsql
      """)

      :ok
    end

    test "a host trigger under another name is neither reported nor removed" do
      Fixtures.sql!("""
      CREATE TRIGGER host_audit AFTER INSERT ON pk_db_foreign
      FOR EACH ROW EXECUTE FUNCTION pk_db_other_fn()
      """)

      refute PhoenixKitDb.has_trigger?("public", "pk_db_foreign")
      refute {"public", "pk_db_foreign"} in PhoenixKitDb.list_triggered_tables()

      assert :ok = PhoenixKitDb.remove_trigger("public", "pk_db_foreign")
      assert :ok = PhoenixKitDb.remove_all_triggers()
      assert triggers_on("pk_db_foreign") == [{"host_audit", "pk_db_other_fn"}]
    end

    test "the prefix alone is not enough: the trigger must call the notify function" do
      Fixtures.sql!("""
      CREATE TRIGGER #{@prefix}lookalike AFTER INSERT ON pk_db_foreign
      FOR EACH ROW EXECUTE FUNCTION pk_db_other_fn()
      """)

      refute PhoenixKitDb.has_trigger?("public", "pk_db_foreign")
      assert :ok = PhoenixKitDb.remove_all_triggers()
      assert triggers_on("pk_db_foreign") == [{@prefix <> "lookalike", "pk_db_other_fn"}]
    end
  end

  describe "remove_trigger/2" do
    test "drops the trigger and leaves the table and other tables' triggers alone" do
      create_table("pk_db_trg")
      create_table("pk_db_trg2")
      assert :ok = PhoenixKitDb.ensure_trigger("public", "pk_db_trg")
      assert :ok = PhoenixKitDb.ensure_trigger("public", "pk_db_trg2")

      assert :ok = PhoenixKitDb.remove_trigger("public", "pk_db_trg")

      assert triggers_on("pk_db_trg") == []
      refute PhoenixKitDb.has_trigger?("public", "pk_db_trg")
      assert PhoenixKitDb.has_trigger?("public", "pk_db_trg2")
      assert %{rows: [[0]]} = Fixtures.sql!("SELECT COUNT(*)::int FROM pk_db_trg")
    end

    test "is :ok on a table that has no trigger" do
      create_table("pk_db_trg")
      assert :ok = PhoenixKitDb.remove_trigger("public", "pk_db_trg")
    end
  end

  describe "list_triggered_tables/0 and remove_all_triggers/0" do
    test "lists each triggered table once, in order, and removes them all" do
      Fixtures.sql!("CREATE SCHEMA pk_db_other")
      Fixtures.sql!("CREATE TABLE pk_db_other.pk_db_trg (id int PRIMARY KEY)")
      create_table("pk_db_trg")
      create_table("pk_db_trg2")
      create_table("pk_db_untouched")

      assert :ok = PhoenixKitDb.ensure_trigger("public", "pk_db_trg2")
      assert :ok = PhoenixKitDb.ensure_trigger("public", "pk_db_trg")
      assert :ok = PhoenixKitDb.ensure_trigger("pk_db_other", "pk_db_trg")

      assert PhoenixKitDb.list_triggered_tables() == [
               {"pk_db_other", "pk_db_trg"},
               {"public", "pk_db_trg"},
               {"public", "pk_db_trg2"}
             ]

      assert :ok = PhoenixKitDb.remove_all_triggers()

      assert PhoenixKitDb.list_triggered_tables() == []
      assert triggers_on("pk_db_trg") == []
      assert triggers_on("pk_db_trg2") == []
    end
  end

  describe "disable_system/0" do
    test "removes every trigger the module installed" do
      create_table("pk_db_trg")
      create_table("pk_db_trg2")
      assert :ok = PhoenixKitDb.ensure_trigger("public", "pk_db_trg")
      assert :ok = PhoenixKitDb.ensure_trigger("public", "pk_db_trg2")
      assert {:ok, _} = PhoenixKitDb.enable_system()
      assert PhoenixKitDb.enabled?()

      assert {:ok, _} = PhoenixKitDb.disable_system()

      refute PhoenixKitDb.enabled?()
      assert PhoenixKitDb.list_triggered_tables() == []
      assert triggers_on("pk_db_trg") == []
      assert triggers_on("pk_db_trg2") == []
    end

    test "enable_system/0 leaves installed triggers in place" do
      create_table("pk_db_trg")
      assert :ok = PhoenixKitDb.ensure_trigger("public", "pk_db_trg")

      assert {:ok, _} = PhoenixKitDb.enable_system()
      assert PhoenixKitDb.has_trigger?("public", "pk_db_trg")

      PhoenixKitDb.disable_system()
    end
  end
end
