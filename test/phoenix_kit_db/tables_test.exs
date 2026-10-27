defmodule PhoenixKitDb.TablesTest do
  @moduledoc """
  `list_tables/1`, `list_table_names/0`, `table_preview/3` and the row shape
  `fetch_row/3` returns, against real tables in the test database.
  """
  use PhoenixKitDb.DataCase, async: false

  alias PhoenixKitDb.Cells
  alias PhoenixKitDb.Fixtures
  alias PhoenixKitDb.QueryCounter

  # Legal Postgres names this module cannot splice into SQL.
  @unsupported_names [
    "pk_db-dash",
    "pk_db.dot",
    "pk_db space",
    "pk_db;semicolon",
    ~s(pk_db"quote),
    "pk_db_newline\n"
  ]

  defp quote_any(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  defp create_unsupported_tables do
    for name <- @unsupported_names do
      Fixtures.sql!("CREATE TABLE #{quote_any(name)} (id int PRIMARY KEY, label text)")
      Fixtures.sql!("INSERT INTO #{quote_any(name)} VALUES (1, 'row')")
    end
  end

  defp create_supported_oddities do
    Fixtures.sql!("CREATE SCHEMA pk_db_other")
    Fixtures.sql!(~s|CREATE TABLE pk_db_other."PkDbUpper" (id int PRIMARY KEY, label text)|)
    Fixtures.sql!(~s|INSERT INTO pk_db_other."PkDbUpper" VALUES (1, 'upper row')|)
  end

  describe "list_tables/1" do
    test "returns one page of entries with their stats, ordered by schema then name" do
      result = PhoenixKitDb.list_tables(%{page: 1, per_page: 10})

      assert result.page == 1
      assert result.per_page == 10
      assert length(result.entries) == 10
      assert result.total_entries > 10
      assert result.total_pages == ceil(result.total_entries / 10)

      keys = Enum.map(result.entries, &{&1.schema, &1.name})
      assert keys == Enum.sort(keys)

      settings = PhoenixKitDb.list_tables(%{search: "phoenix_kit_settings"})
      assert [%{schema: "public", name: "phoenix_kit_settings"} = entry] = settings.entries
      assert entry.size_bytes > 0
      assert entry.approx_rows >= 0
    end

    test "page 2 continues where page 1 stopped" do
      page1 = PhoenixKitDb.list_tables(%{page: 1, per_page: 5})
      page2 = PhoenixKitDb.list_tables(%{page: 2, per_page: 5})
      both = PhoenixKitDb.list_tables(%{page: 1, per_page: 10})

      assert page1.entries ++ page2.entries == both.entries
    end

    test "the page size is clamped to 100" do
      result = PhoenixKitDb.list_tables(%{page: 1, per_page: 1000})

      assert result.per_page == 100
      assert length(result.entries) == min(result.total_entries, 100)
    end

    test "search matches the schema or the table name, case-insensitively" do
      create_supported_oddities()

      by_table = PhoenixKitDb.list_tables(%{search: "pkdbupper"})
      assert [%{schema: "pk_db_other", name: "PkDbUpper"}] = by_table.entries
      assert by_table.total_entries == 1

      by_schema = PhoenixKitDb.list_tables(%{search: "PK_DB_OTHER"})
      assert [%{schema: "pk_db_other", name: "PkDbUpper"}] = by_schema.entries

      assert PhoenixKitDb.list_tables(%{search: "pk_db_no_such_table"}).entries == []
    end

    test "tables it cannot open are left out and counted" do
      before = PhoenixKitDb.list_tables(%{})

      create_unsupported_tables()
      create_supported_oddities()

      result = PhoenixKitDb.list_tables(%{search: "pk_db", per_page: 100})
      names = Enum.map(result.entries, & &1.name)

      assert names == ["PkDbUpper"]
      assert result.total_entries == 1
      assert result.hidden_count == before.hidden_count + length(@unsupported_names)

      # The hidden count does not depend on the search.
      assert PhoenixKitDb.list_tables(%{}).hidden_count == result.hidden_count
      assert PhoenixKitDb.list_tables(%{}).total_entries == before.total_entries + 1
    end
  end

  describe "list_table_names/0" do
    test "returns every openable table, past what one list_tables page can hold" do
      create_filler_tables!()
      create_unsupported_tables()
      create_supported_oddities()

      names = PhoenixKitDb.list_table_names()
      total = PhoenixKitDb.list_tables(%{}).total_entries

      assert total > 100, "the schema is expected to have more than 100 tables"
      assert length(names) == total
      assert names == Enum.sort(names)
      assert {"public", "phoenix_kit_settings"} in names
      assert {"pk_db_other", "PkDbUpper"} in names

      for name <- @unsupported_names do
        refute {"public", name} in names
      end
    end
  end

  describe "table_preview/3 on names" do
    test "an unsupported name answers with the empty preview, never a query error" do
      create_unsupported_tables()

      for name <- @unsupported_names do
        preview = PhoenixKitDb.table_preview("public", name)

        assert preview.columns == [], "#{inspect(name)} must not be opened"
        assert preview.rows == []
      end

      assert PhoenixKitDb.table_preview("pk-db", "phoenix_kit_settings").columns == []
    end

    test "a trailing newline is not the table without it" do
      assert PhoenixKitDb.table_preview("public", "phoenix_kit_settings\n").columns == []
      assert PhoenixKitDb.table_preview("public\n", "phoenix_kit_settings").columns == []

      assert {:error, :invalid_identifier} =
               PhoenixKitDb.fetch_row("public", "phoenix_kit_settings\n", "1")

      assert {:error, :invalid_identifier} =
               PhoenixKitDb.ensure_trigger("public", "phoenix_kit_settings\n")
    end

    test "an uppercase table in a non-public schema opens" do
      create_supported_oddities()

      preview = PhoenixKitDb.table_preview("pk_db_other", "PkDbUpper")

      assert Enum.map(preview.columns, & &1.name) == ["id", "label"]
      assert preview.rows == [%{"id" => 1, "label" => "upper row"}]
      assert preview.row_count == 1

      assert {:ok, %{"label" => "upper row"}} =
               PhoenixKitDb.fetch_row("pk_db_other", "PkDbUpper", 1)
    end

    test "a table that does not exist answers with the empty preview" do
      preview = PhoenixKitDb.table_preview("public", "pk_db_definitely_absent")

      assert preview.columns == []
      assert preview.row_count == 0
      assert preview.total_pages == 1
    end
  end

  describe "table_preview/3 rows" do
    test "secret-named columns come back masked and the secrets are nowhere in the preview" do
      Fixtures.create_secrets_table()

      preview = PhoenixKitDb.table_preview("public", "pk_db_secrets")
      assert [row] = preview.rows

      for column <- ~w(hashed_password API_KEY refresh_token webhook_secret password_salt) do
        assert row[column] == Cells.masked_placeholder(), "#{column} is not masked"
      end

      assert row["reset_token"] == nil
      assert row["email"] == "visible@example.com"
      assert row["note"] == "plain note"
      assert row["settings"]["theme"] == "dark"
      assert row["settings"]["smtp_password"] == Cells.masked_placeholder()
      assert row["settings"]["nested"]["client_secret"] == Cells.masked_placeholder()

      dump = inspect(preview, limit: :infinity, printable_limit: :infinity)

      for marker <- Fixtures.secret_markers() do
        refute dump =~ marker
      end
    end

    test "uuid columns are canonical text, uuid arrays too" do
      uuid = Fixtures.create_types_table()

      assert [row] = PhoenixKitDb.table_preview("public", "pk_db_types").rows

      assert row["uuid"] == uuid
      assert row["uuids"] == [Fixtures.element_uuid()]
      # A 4-byte bytea stays a binary; only uuid-typed columns are decoded.
      assert row["raw"] == <<0xDE, 0xAD, 0xBE, 0xEF>>
    end

    test "primary_key names the columns that tell rows apart" do
      Fixtures.create_types_table()
      Fixtures.sql!("CREATE TABLE pk_db_no_pk (a int, b text)")
      Fixtures.sql!("CREATE TABLE pk_db_composite (a int, b int, c text, PRIMARY KEY (a, b))")
      Fixtures.sql!("CREATE TABLE pk_db_secret_pk (token text PRIMARY KEY, label text)")

      assert PhoenixKitDb.table_preview("public", "pk_db_types").primary_key == ["uuid"]
      assert PhoenixKitDb.table_preview("public", "pk_db_no_pk").primary_key == []
      assert PhoenixKitDb.table_preview("public", "pk_db_composite").primary_key == ["a", "b"]
      # Every row of a masked key holds the same placeholder.
      assert PhoenixKitDb.table_preview("public", "pk_db_secret_pk").primary_key == []
    end

    test "pagination windows the rows and counts them exactly" do
      Fixtures.sql!("CREATE TABLE pk_db_pages (id int PRIMARY KEY)")
      Fixtures.sql!("INSERT INTO pk_db_pages SELECT generate_series(1, 25)")

      page2 = PhoenixKitDb.table_preview("public", "pk_db_pages", %{page: 2, per_page: 10})

      assert Enum.map(page2.rows, & &1["id"]) == Enum.to_list(11..20)
      assert page2.row_count == 25
      assert page2.row_count_approx == false
      assert page2.total_pages == 3

      last = PhoenixKitDb.table_preview("public", "pk_db_pages", %{page: 999, per_page: 10})
      assert last.page == 3
      assert Enum.map(last.rows, & &1["id"]) == Enum.to_list(21..25)
    end
  end

  describe "table_preview/3 search" do
    test "citext columns are searchable despite their USER-DEFINED catalog type" do
      Fixtures.sql!("CREATE EXTENSION IF NOT EXISTS citext")
      Fixtures.sql!("CREATE TABLE pk_db_citext (id int PRIMARY KEY, label citext)")
      Fixtures.sql!("INSERT INTO pk_db_citext VALUES (1, 'CaseInsensitive')")
      preview = PhoenixKitDb.table_preview("public", "pk_db_citext", %{search: "caseinsensitive"})
      assert [%{"id" => 1}] = preview.rows
      assert Enum.find(preview.columns, &(&1.name == "label")).data_type == "citext"
    end

    test "varchar and fixed-width character columns are searchable" do
      Fixtures.sql!(
        "CREATE TABLE pk_db_chars (id int PRIMARY KEY, label varchar(50), code char(20))"
      )

      Fixtures.sql!("INSERT INTO pk_db_chars VALUES (1, 'varchar-match', 'char-match')")

      for term <- ["varchar-match", "char-match"] do
        assert [%{"id" => 1}] =
                 PhoenixKitDb.table_preview("public", "pk_db_chars", %{search: term}).rows
      end
    end

    test "searching a table with only masked or JSON columns returns no matches" do
      Fixtures.sql!(
        "CREATE TABLE pk_db_unsearchable (id int PRIMARY KEY, signing_key text, doc jsonb)"
      )

      Fixtures.sql!(~s|INSERT INTO pk_db_unsearchable VALUES (1, 'LEAK', '{"pwd":"LEAK"}')|)
      assert [_] = PhoenixKitDb.table_preview("public", "pk_db_unsearchable").rows

      for term <- ["LEAK", "anything"] do
        preview = PhoenixKitDb.table_preview("public", "pk_db_unsearchable", %{search: term})
        assert preview.rows == []
        assert preview.row_count == 0
      end
    end

    test "unsupported column names do not raise while searching a supported table" do
      Fixtures.sql!(
        ~s|CREATE TABLE pk_db_column_names (id int PRIMARY KEY, "odd-name" text, label text)|
      )

      Fixtures.sql!("INSERT INTO pk_db_column_names VALUES (1, 'odd', 'findable')")

      assert [%{"odd-name" => "odd"}] =
               PhoenixKitDb.table_preview("public", "pk_db_column_names", %{search: "findable"}).rows
    end

    test "uppercase key/value columns cannot be searched for masked secrets" do
      Fixtures.sql!(
        ~s|CREATE TABLE pk_db_upper (id int PRIMARY KEY, "Key" text, "Value" varchar(50))|
      )

      Fixtures.sql!("INSERT INTO pk_db_upper VALUES (1, 'pwd', 'LEAK-uppercase')")
      assert [%{"Value" => masked}] = PhoenixKitDb.table_preview("public", "pk_db_upper").rows
      assert masked == Cells.masked_placeholder()

      assert [] ==
               PhoenixKitDb.table_preview("public", "pk_db_upper", %{search: "LEAK-uppercase"}).rows
    end

    setup do
      Fixtures.create_secrets_table()
      :ok
    end

    test "matches a visible text column, case-insensitively" do
      found = PhoenixKitDb.table_preview("public", "pk_db_secrets", %{search: "VISIBLE@example"})

      assert found.row_count == 1
      assert [%{"email" => "visible@example.com"}] = found.rows

      missed = PhoenixKitDb.table_preview("public", "pk_db_secrets", %{search: "nobody@"})
      assert missed.row_count == 0
      assert missed.rows == []
    end

    test "never looks inside a masked column, so a guessed secret confirms nothing" do
      for guess <- ["LEAK-bcrypt-hash", "LEAK-api-key", "LEAK-refresh", "LEAK-webhook", "bcrypt"] do
        {preview, statements} =
          QueryCounter.capture(fn ->
            PhoenixKitDb.table_preview("public", "pk_db_secrets", %{search: guess})
          end)

        assert preview.row_count == 0, "searching #{inspect(guess)} found the row"
        assert preview.rows == []

        for statement <- statements, statement =~ "ILIKE" do
          for column <- ~w(hashed_password API_KEY refresh_token webhook_secret reset_token) do
            refute statement =~ ~s("#{column}"), "the search reads #{column}"
          end

          assert statement =~ ~s("email")
        end
      end
    end
  end

  describe "table_preview/3 search and what masking hides" do
    defp search(table, term) do
      QueryCounter.capture(fn ->
        PhoenixKitDb.table_preview("public", table, %{search: term})
      end)
    end

    test "a secret under a JSON key is not found, the row still is by a plain column" do
      Fixtures.create_secrets_table()

      for guess <- ["LEAK-nested", "LEAK-deep", "smtp_password"] do
        {preview, statements} = search("pk_db_secrets", guess)

        assert preview.rows == [], "searching #{inspect(guess)} found the row"
        assert preview.row_count == 0

        for statement <- statements, statement =~ "ILIKE" do
          refute statement =~ ~s("settings"), "the search reads the JSON column"
        end
      end

      {found, _} = search("pk_db_secrets", "plain note")
      assert [%{"note" => "plain note"} = row] = found.rows
      assert row["settings"]["smtp_password"] == Cells.masked_placeholder()
    end

    test "a json column is skipped like a jsonb one" do
      Fixtures.sql!("CREATE TABLE pk_db_json (id int PRIMARY KEY, doc json, label text)")

      Fixtures.sql!(
        ~s|INSERT INTO pk_db_json VALUES (1, '{"api_token": "s3cr3t-json"}', 'json label')|
      )

      {missed, _} = search("pk_db_json", "s3cr3t-json")
      assert missed.rows == []
      assert missed.row_count == 0

      {found, _} = search("pk_db_json", "json label")
      assert [%{"doc" => %{"api_token" => masked}}] = found.rows
      assert masked == Cells.masked_placeholder()
    end

    for key_column <- ~w(key name) do
      test "a #{key_column}/value row with a secret #{key_column} is not found by its value" do
        key_column = unquote(key_column)

        Fixtures.sql!("""
        CREATE TABLE pk_db_kv (
          id int PRIMARY KEY, #{key_column} text, value text, value_text varchar(50), note text
        )
        """)

        Fixtures.sql!("""
        INSERT INTO pk_db_kv VALUES
          (1, 'api_token', 's3cr3t-one', 's3cr3t-two', 'harmless note'),
          (2, 'site_title', 'My Shop', 'shop text', 'other note')
        """)

        for guess <- ["s3cr3t-one", "s3cr3t-two", "s3cr3t"] do
          {preview, statements} = search("pk_db_kv", guess)

          assert preview.rows == [], "searching #{inspect(guess)} found the row"
          assert preview.row_count == 0

          for statement <- statements, statement =~ "ILIKE" do
            refute statement =~ ~s("value")
            refute statement =~ ~s("value_text")
          end
        end

        # The masked row is still found by what the page shows of it.
        for term <- ["harmless", "api_token"] do
          {found, _} = search("pk_db_kv", term)

          assert [%{"id" => 1} = row] = found.rows
          assert row["value"] == Cells.masked_placeholder()
          assert row["value_text"] == Cells.masked_placeholder()
          assert row["note"] == "harmless note"
        end

        {plain, _} = search("pk_db_kv", "site_title")
        assert [%{"id" => 2, "value" => "My Shop"}] = plain.rows
      end
    end

    test "a value column is searched on a table with no key or name column" do
      Fixtures.sql!("CREATE TABLE pk_db_values (id int PRIMARY KEY, label text, value text)")
      Fixtures.sql!("INSERT INTO pk_db_values VALUES (1, 'api_token', 'findable value')")

      {found, _} = search("pk_db_values", "findable")
      assert [%{"value" => "findable value"}] = found.rows
    end
  end

  describe "table_preview/3 row total" do
    test "a large table reports the planner estimate and runs no COUNT" do
      Fixtures.sql!("CREATE TABLE pk_db_big (id int PRIMARY KEY)")
      Fixtures.sql!("INSERT INTO pk_db_big SELECT generate_series(1, 100500)")
      Fixtures.sql!("ANALYZE pk_db_big")

      {preview, statements} =
        QueryCounter.capture(fn -> PhoenixKitDb.table_preview("public", "pk_db_big") end)

      assert preview.row_count_approx == true
      assert_in_delta preview.row_count, 100_500, 10_050
      assert preview.total_pages == ceil(preview.row_count / preview.per_page)
      assert length(preview.rows) == preview.per_page
      assert QueryCounter.count(statements, "COUNT(*)") == 0
    end

    test "a small table is counted exactly, analyzed or not" do
      Fixtures.sql!("CREATE TABLE pk_db_small (id int PRIMARY KEY)")
      Fixtures.sql!("INSERT INTO pk_db_small SELECT generate_series(1, 7)")

      {preview, statements} =
        QueryCounter.capture(fn -> PhoenixKitDb.table_preview("public", "pk_db_small") end)

      assert preview.row_count == 7
      assert preview.row_count_approx == false
      assert QueryCounter.count(statements, ~s|COUNT(*) FROM "public"."pk_db_small"|) == 1

      Fixtures.sql!("ANALYZE pk_db_small")
      assert PhoenixKitDb.table_preview("public", "pk_db_small").row_count_approx == false
    end
  end

  describe "fetch_row/3 row shape" do
    test "masks secrets the same way the preview does" do
      id = Fixtures.create_secrets_table()

      assert {:ok, row} = PhoenixKitDb.fetch_row("public", "pk_db_secrets", id)

      assert row["hashed_password"] == Cells.masked_placeholder()
      assert row["API_KEY"] == Cells.masked_placeholder()
      assert row["reset_token"] == nil
      assert row["email"] == "visible@example.com"

      dump = inspect(row, limit: :infinity, printable_limit: :infinity)

      for marker <- Fixtures.secret_markers() do
        refute dump =~ marker
      end
    end

    test "returns uuid columns as canonical text" do
      uuid = Fixtures.create_types_table()

      assert {:ok, row} = PhoenixKitDb.fetch_row("public", "pk_db_types", uuid)
      assert row["uuid"] == uuid
      assert row["uuids"] == [Fixtures.element_uuid()]
    end
  end
end
