defmodule PhoenixKitDb.FetchRowTest do
  @moduledoc """
  Regression cover for `PhoenixKitDb.fetch_row/3`'s parameter binding.

  Two defects lived here, both of which the Activity feed hits from
  `handle_info/2` on a LISTEN/NOTIFY payload naming an arbitrary table --
  the one place in this module where an escaping exception kills a LiveView.

    1. A `uuid` primary key never resolved AT ALL. `WHERE "uuid" = $1` makes
       Postgres resolve `$1` to `uuid`, so Postgrex demanded a raw 16-byte
       binary and raised `DBConnection.EncodeError` on the 36-byte canonical
       string. Every PhoenixKit table has a UUIDv7 primary key, so the feed's
       per-key row diff was dead for all of them.

    2. `RepoHelper.get_pk_column/1` RAISES `ArgumentError` when a table has no
       primary key, has a composite one, or does not exist. All three are
       ordinary "nothing to show" for a read-only explorer.
  """
  use PhoenixKitDb.DataCase, async: false

  alias PhoenixKit.RepoHelper

  test "text and varchar primary keys preserve colons, leading zeros and empty strings" do
    for {table, type} <- [{"pk_db_text_pk", "text"}, {"pk_db_varchar_pk", "varchar(100)"}] do
      RepoHelper.query!("CREATE TABLE #{table} (id #{type} PRIMARY KEY, label text)", [])

      for id <- ["user:42:web", "00123", "123", "", "O'Brien"] do
        RepoHelper.query!("INSERT INTO #{table} VALUES ($1, 'found')", [id])

        assert {:ok, %{"id" => ^id, "label" => "found"}} =
                 PhoenixKitDb.fetch_row("public", table, id)
      end

      assert {:ok, %{"id" => "123"}} = PhoenixKitDb.fetch_row("public", table, 123)
      assert {:error, :not_found} = PhoenixKitDb.fetch_row("public", table, "missing")
    end
  end

  test "integer IDs bind by the column type and reject malformed or out-of-range values" do
    RepoHelper.query!("CREATE TABLE pk_db_int_pk (id smallint PRIMARY KEY)", [])
    RepoHelper.query!("INSERT INTO pk_db_int_pk VALUES (12)", [])
    assert {:ok, %{"id" => 12}} = PhoenixKitDb.fetch_row("public", "pk_db_int_pk", "12")
    assert {:error, :invalid_id} = PhoenixKitDb.fetch_row("public", "pk_db_int_pk", "12tail")
    assert {:error, :invalid_id} = PhoenixKitDb.fetch_row("public", "pk_db_int_pk", "40000")
  end

  test "included index columns are not mistaken for composite primary keys" do
    RepoHelper.query!(
      "CREATE TABLE pk_db_include (id int, label text, PRIMARY KEY (id) INCLUDE (label))",
      []
    )

    RepoHelper.query!("INSERT INTO pk_db_include VALUES (1, 'included')", [])

    assert {:ok, %{"label" => "included"}} =
             PhoenixKitDb.fetch_row("public", "pk_db_include", "1")

    assert PhoenixKitDb.table_preview("public", "pk_db_include").primary_key == ["id"]
  end

  describe "fetch_row/3 with a uuid primary key" do
    test "a valid uuid string resolves the row" do
      # phoenix_kit_settings is core-owned and always populated after the
      # migration chain runs, so this needs no fixture of its own.
      {:ok, %{rows: [[raw_uuid]]}} =
        RepoHelper.query("SELECT uuid FROM phoenix_kit_settings LIMIT 1", [])

      uuid = Ecto.UUID.cast!(raw_uuid)

      assert {:ok, row} = PhoenixKitDb.fetch_row("public", "phoenix_kit_settings", uuid)
      assert Map.has_key?(row, "key")
      assert row["uuid"] == uuid
    end

    test "an integer-shaped id is refused without querying and never raises" do
      assert {:error, :invalid_id} =
               PhoenixKitDb.fetch_row("public", "phoenix_kit_settings", "12345")
    end

    test "a well-formed but absent uuid is :not_found, not an error" do
      absent = Ecto.UUID.generate()

      assert {:error, :not_found} =
               PhoenixKitDb.fetch_row("public", "phoenix_kit_settings", absent)
    end
  end

  describe "fetch_row/3 on tables it cannot key" do
    setup do
      RepoHelper.query!("CREATE TABLE IF NOT EXISTS pk_db_no_pk (a int, b text)", [])

      RepoHelper.query!(
        "CREATE TABLE IF NOT EXISTS pk_db_composite_pk (a int, b int, PRIMARY KEY (a, b))",
        []
      )

      on_exit(fn ->
        RepoHelper.query("DROP TABLE IF EXISTS pk_db_no_pk", [])
        RepoHelper.query("DROP TABLE IF EXISTS pk_db_composite_pk", [])
      end)

      :ok
    end

    test "a table with no primary key returns an error tuple" do
      assert {:error, :no_primary_key} = PhoenixKitDb.fetch_row("public", "pk_db_no_pk", "1")
    end

    test "a composite primary key returns an error tuple" do
      assert {:error, :composite_primary_key} =
               PhoenixKitDb.fetch_row("public", "pk_db_composite_pk", "1")
    end

    test "a table that does not exist returns an error tuple" do
      assert {:error, :no_primary_key} =
               PhoenixKitDb.fetch_row("public", "pk_db_definitely_absent", "1")
    end
  end
end
