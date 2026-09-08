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

  describe "fetch_row/3 with a uuid primary key" do
    test "a valid uuid string resolves the row" do
      # phoenix_kit_settings is core-owned and always populated after the
      # migration chain runs, so this needs no fixture of its own.
      {:ok, %{rows: [[raw_uuid]]}} =
        RepoHelper.query("SELECT uuid FROM phoenix_kit_settings LIMIT 1", [])

      uuid = Ecto.UUID.cast!(raw_uuid)

      assert {:ok, row} = PhoenixKitDb.fetch_row("public", "phoenix_kit_settings", uuid)
      assert Map.has_key?(row, "key")
      assert row["uuid"] == raw_uuid
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
