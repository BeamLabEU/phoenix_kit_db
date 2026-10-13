defmodule PhoenixKitDb.Fixtures do
  @moduledoc """
  Throwaway tables for tests that need a known shape.

  Everything here runs through the test repo, so inside the SQL sandbox it is
  rolled back with the test. Tests that need COMMITTED tables (a real NOTIFY, a
  lock held by a second connection) wrap the calls in `unboxed/1` and drop the
  tables themselves.
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitDb.Test.Repo, as: TestRepo

  @type_uuid "018f3c1e-7a2b-7c3d-8e4f-5a6b7c8d9e0f"
  @element_uuid "018f3c1e-7a2b-7c3d-8e4f-000000000001"

  def sql!(statement, params \\ []), do: TestRepo.query!(statement, params)

  @doc "Runs `fun` on a real, auto-committing connection, outside the sandbox."
  def unboxed(fun), do: Sandbox.unboxed_run(TestRepo, fun)

  def type_uuid, do: @type_uuid
  def element_uuid, do: @element_uuid

  @doc """
  One row in `pk_db_secrets`: every denylisted name shape next to plain
  columns, each secret value carrying a `LEAK-` marker a test can grep for.
  """
  def create_secrets_table do
    sql!("""
    CREATE TABLE pk_db_secrets (
      id bigserial PRIMARY KEY,
      email text,
      hashed_password text,
      "API_KEY" text,
      refresh_token text,
      webhook_secret text,
      password_salt bytea,
      reset_token text,
      settings jsonb,
      note text
    )
    """)

    sql!("""
    INSERT INTO pk_db_secrets
      (email, hashed_password, "API_KEY", refresh_token, webhook_secret, password_salt,
       reset_token, settings, note)
    VALUES
      ('visible@example.com', 'LEAK-bcrypt-hash', 'LEAK-api-key', 'LEAK-refresh',
       'LEAK-webhook', 'LEAK-salt'::bytea, NULL,
       '{"theme": "dark", "smtp_password": "LEAK-nested", "nested": {"client_secret": "LEAK-deep"}}',
       'plain note')
    """)

    %{rows: [[id]]} = sql!("SELECT id FROM pk_db_secrets")
    id
  end

  def secret_markers do
    ~w(LEAK-bcrypt-hash LEAK-api-key LEAK-refresh LEAK-webhook LEAK-salt LEAK-nested LEAK-deep)
  end

  @doc """
  One row in `pk_db_types` covering every value shape a page has to print.
  Returns the row's uuid as text.
  """
  def create_types_table do
    sql!("""
    CREATE TABLE pk_db_types (
      uuid uuid PRIMARY KEY,
      amount numeric(12,2),
      day date,
      clock time,
      stamp timestamp,
      stamp_tz timestamptz,
      stamp_frac timestamp,
      ip inet,
      net cidr,
      mac macaddr,
      span interval,
      int_range int4range,
      empty_range int4range,
      open_range tstzrange,
      ints int[],
      texts text[],
      uuids uuid[],
      doc jsonb,
      raw bytea,
      flag boolean,
      ratio float8,
      spot point,
      words tsvector,
      big bigint,
      label text,
      missing text
    )
    """)

    sql!("""
    INSERT INTO pk_db_types VALUES (
      '#{@type_uuid}', 1234.50, '2024-02-29', '13:14:15', '2024-02-29 13:14:15',
      '2024-02-29 13:14:15+00', '2024-02-29 13:14:15.25', '10.1.2.3', '10.0.0.0/8',
      '08:00:2b:01:02:03', '1 year 2 mons 3 days 04:05:06', '[1,5)', 'empty',
      '[2024-01-01 00:00:00+00,)', '{1,2,3}', '{a,b}', '{#{@element_uuid}}',
      '{"a": {"b": [1, "x"]}}', '\\xdeadbeef', true, 1.5, '(1,2)', 'fat cat',
      9007199254740993, 'plain', NULL
    )
    """)

    @type_uuid
  end

  @doc "The text each `pk_db_types` column must render as."
  def expected_type_texts do
    %{
      "uuid" => @type_uuid,
      "amount" => "1234.50",
      "day" => "2024-02-29",
      "clock" => "13:14:15",
      "stamp" => "2024-02-29 13:14:15",
      "stamp_tz" => "2024-02-29 13:14:15Z",
      "stamp_frac" => "2024-02-29 13:14:15.250000",
      "ip" => "10.1.2.3",
      "net" => "10.0.0.0/8",
      "mac" => "08:00:2b:01:02:03",
      "span" => "1 year 2 mons 3 days 04:05:06",
      "int_range" => "[1,5)",
      "empty_range" => "empty",
      "open_range" => "[2024-01-01 00:00:00Z,)",
      "ints" => "[1,2,3]",
      "texts" => ~s(["a","b"]),
      "uuids" => ~s(["#{@element_uuid}"]),
      "doc" => ~s({"a":{"b":[1,"x"]}}),
      "raw" => "\\xdeadbeef",
      "flag" => "true",
      "ratio" => "1.5",
      "big" => "9007199254740993",
      "label" => "plain"
    }
  end
end
