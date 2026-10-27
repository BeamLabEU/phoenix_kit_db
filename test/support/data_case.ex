defmodule PhoenixKitDb.DataCase do
  @moduledoc """
  Test case for tests requiring database access.

  Uses `PhoenixKitDb.Test.Repo` with SQL Sandbox for isolation. Tests
  using this case are tagged `:integration` and will be automatically
  excluded when the database is unavailable.

  ## Usage

      defmodule MyModule.Integration.SomeTest do
        use PhoenixKitDb.DataCase, async: true

        test "queries the DB" do
          # Repo is available, transactions are isolated
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitDb.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitDb.ActivityLogAssertions
      import PhoenixKitDb.DataCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitDb.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end

  @doc """
  Translates changeset errors into a `%{field => [message]}` map.
  Used by tests that assert on changeset error messages.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Pads the schema with empty tables so there are more than one page (100) of
  them. Core 3.0 creates about 40 tables on its own; the modules' tables made
  up the rest of the hundred. The tables vanish with the sandbox transaction.
  """
  def create_filler_tables!(count \\ 110) do
    for n <- 1..count do
      TestRepo.query!("CREATE TABLE IF NOT EXISTS pk_db_fill_#{n} (id integer)")
    end

    :ok
  end
end
