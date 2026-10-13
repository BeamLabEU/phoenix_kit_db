defmodule PhoenixKitDbTest do
  use ExUnit.Case

  # `function_exported?/3` answers FALSE for a module that is merely not
  # loaded, not only for one that lacks the function, so a bare callback
  # assertion fails intermittently under a random seed and never when the file
  # runs alone -- the shape that reads as flaky infrastructure and gets re-run
  # instead of fixed. Reproduced in two sibling modules before this went in.
  setup_all do
    Code.ensure_loaded!(PhoenixKitDb)
    :ok
  end

  # Verifies the PhoenixKit.Module behaviour contract — copy and adapt
  # for any new module you build.

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitDb.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitDb.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns 'db'" do
      assert PhoenixKitDb.module_key() == "db"
    end

    test "module_name/0 returns 'DB'" do
      assert PhoenixKitDb.module_name() == "DB"
    end

    test "enabled?/0 answers false, without raising, when the setting cannot be read" do
      # No sandbox owner here, so the settings query itself fails.
      assert PhoenixKitDb.enabled?() == false
    end
  end

  describe "permission_metadata/0" do
    # Core mirrors these three values as its fallback for the `db` key, so a
    # change here needs the same change there.
    test "declares the key, label, icon and description core mirrors" do
      assert PhoenixKitDb.permission_metadata() == %{
               key: "db",
               label: "DB",
               icon: "hero-server-stack",
               description: "Database explorer and schema inspection",
               gettext_backend: PhoenixKitDb.Gettext,
               gettext_domain: "default"
             }
    end

    test "key matches module_key" do
      meta = PhoenixKitDb.permission_metadata()
      assert meta.key == PhoenixKitDb.module_key()
    end
  end

  describe "admin_tabs/0" do
    test "returns four tabs (parent + overview + activity + hidden show)" do
      tabs = PhoenixKitDb.admin_tabs()
      assert length(tabs) == 4
    end

    test "main tab has all required fields" do
      [main | _] = PhoenixKitDb.admin_tabs()
      assert main.id == :admin_db
      assert main.label == "DB"
      assert main.path == "db"
      assert main.level == :admin
      assert main.permission == PhoenixKitDb.module_key()
      assert main.group == :admin_modules
    end

    test "main tab has live_view for route generation" do
      [main | _] = PhoenixKitDb.admin_tabs()
      assert {PhoenixKitDb.Web.IndexLive, :index} = main.live_view
    end

    test "all tab paths use hyphens not underscores" do
      for tab <- PhoenixKitDb.admin_tabs() do
        refute String.contains?(tab.path, "_")
      end
    end

    test "all tabs share the same permission (module_key)" do
      for tab <- PhoenixKitDb.admin_tabs() do
        assert tab.permission == PhoenixKitDb.module_key()
      end
    end

    test "all subtabs reference the main tab as parent" do
      [main | subtabs] = PhoenixKitDb.admin_tabs()

      for tab <- subtabs do
        assert tab.parent == main.id
      end
    end

    test "includes Activity subtab pointing to ActivityLive" do
      tabs = PhoenixKitDb.admin_tabs()
      activity = Enum.find(tabs, &(&1.id == :admin_db_activity))

      assert activity != nil
      assert activity.label == "Activity"
      assert activity.path == "db/activity"
      assert activity.live_view == {PhoenixKitDb.Web.ActivityLive, :activity}
    end

    test "includes hidden Show subtab with :schema/:table dynamic segments" do
      tabs = PhoenixKitDb.admin_tabs()
      show = Enum.find(tabs, &(&1.id == :admin_db_show))

      assert show != nil
      assert show.visible == false
      assert show.path == "db/:schema/:table"
      assert show.live_view == {PhoenixKitDb.Web.ShowLive, :show}
    end
  end

  describe "version/0" do
    test "returns a version string" do
      assert PhoenixKitDb.version() == Mix.Project.config()[:version]
    end
  end

  describe "css_sources/0" do
    test "returns a list with the OTP app atom" do
      assert PhoenixKitDb.css_sources() == [:phoenix_kit_db]
    end
  end

  describe "js_sources/0" do
    test "declares the prebuilt bundle and the file ships in priv/" do
      assert [%{app: :phoenix_kit_db, file: file, global: "PhoenixKitDbHooks"}] =
               PhoenixKitDb.js_sources()

      assert File.exists?(Path.join(:code.priv_dir(:phoenix_kit_db), file))
    end

    test "the bundle defines the namespaced hook under its global" do
      js =
        :phoenix_kit_db
        |> :code.priv_dir()
        |> Path.join("static/assets/phoenix_kit_db.js")
        |> File.read!()

      assert js =~ "window.PhoenixKitDbHooks"
      assert js =~ "PhoenixKitDbTableScroller"
    end

    # The hook must reach the host's LiveSocket through the bundle: morphdom
    # does not execute a <script> it inserts, so a hook registered inline is
    # dead after any LiveView navigation into the page.
    test "the Show template uses the bundled hook and registers nothing inline" do
      template = File.read!("lib/phoenix_kit_db/web/show_live.html.heex")

      assert template =~ ~s(phx-hook="PhoenixKitDbTableScroller")
      refute template =~ "<script"
    end
  end

  describe "children/0" do
    test "starts the Listener GenServer" do
      assert PhoenixKitDb.children() == [PhoenixKitDb.Listener]
    end
  end

  describe "optional callbacks have defaults" do
    test "settings_tabs/0 returns empty list" do
      assert PhoenixKitDb.settings_tabs() == []
    end

    test "user_dashboard_tabs/0 returns empty list" do
      assert PhoenixKitDb.user_dashboard_tabs() == []
    end

    test "route_module/0 returns nil" do
      assert PhoenixKitDb.route_module() == nil
    end

    test "required_integrations/0 returns empty list" do
      assert PhoenixKitDb.required_integrations() == []
    end

    test "integration_providers/0 returns empty list" do
      assert PhoenixKitDb.integration_providers() == []
    end
  end

  describe "Paths" do
    alias PhoenixKitDb.Paths

    test "index/0 returns a path string ending in /admin/db" do
      assert String.ends_with?(Paths.index(), "/admin/db")
    end

    test "activity/0 returns the activity subpath" do
      path = Paths.activity()
      assert String.ends_with?(path, "/admin/db/activity")
    end

    test "show/2 returns the schema/table subpath" do
      path = Paths.show("public", "phoenix_kit_users")
      assert String.ends_with?(path, "/admin/db/public/phoenix_kit_users")
    end

    test "all Paths helpers stay under the index prefix" do
      assert String.starts_with?(Paths.activity(), Paths.index())
      assert String.starts_with?(Paths.show("public", "x"), Paths.index())
    end
  end

  describe "i18n wiring" do
    alias PhoenixKit.Dashboard.Tab

    test "every tab carries the module's own gettext backend" do
      for tab <- PhoenixKitDb.admin_tabs() do
        assert tab.gettext_backend == PhoenixKitDb.Gettext
        assert tab.gettext_domain == "default"
      end
    end

    test "every tab and permission label is pinned as a msgid" do
      labels = Enum.map(PhoenixKitDb.admin_tabs(), & &1.label)

      assert Enum.sort(Enum.uniq([PhoenixKitDb.permission_metadata().label | labels])) ==
               Enum.sort(PhoenixKitDb.translatable_labels())
    end

    test "tab labels resolve through the module's catalogue" do
      tabs = Map.new(PhoenixKitDb.admin_tabs(), &{&1.id, &1})

      expected = %{
        "ru" => %{
          admin_db: "БД",
          admin_db_overview: "Обзор",
          admin_db_activity: "Активность",
          admin_db_show: "Таблица"
        },
        "et" => %{
          admin_db: "Andmebaas",
          admin_db_overview: "Ülevaade",
          admin_db_activity: "Tegevus",
          admin_db_show: "Tabel"
        }
      }

      for {locale, labels} <- expected, {id, label} <- labels do
        Gettext.with_locale(PhoenixKitDb.Gettext, locale, fn ->
          assert Tab.localized_label(tabs[id]) == label
        end)
      end
    end

    test "plurals follow each locale's forms" do
      forms = fn locale, count ->
        Gettext.with_locale(PhoenixKitDb.Gettext, locale, fn ->
          Gettext.dngettext(PhoenixKitDb.Gettext, "default", "event", "events", count)
        end)
      end

      assert Enum.map([1, 2, 5, 21], &forms.("ru", &1)) ==
               ["событие", "события", "событий", "событие"]

      assert Enum.map([1, 2], &forms.("et", &1)) == ["sündmus", "sündmust"]
      assert Enum.map([1, 2], &forms.("en", &1)) == ["event", "events"]
    end

    test "no catalogue entry is left untranslated or fuzzy in et and ru" do
      for locale <- ["et", "ru"] do
        {:ok, po} =
          :phoenix_kit_db
          |> :code.priv_dir()
          |> Path.join("gettext/#{locale}/LC_MESSAGES/default.po")
          |> Expo.PO.parse_file()

        assert length(po.messages) > 50

        for message <- po.messages do
          refute Enum.any?(message.flags, &("fuzzy" in &1)),
                 "#{locale}: #{inspect(message.msgid)} is fuzzy"

          refute message.msgstr |> msgstr_texts() |> Enum.any?(&(&1 == "")),
                 "#{locale}: #{inspect(message.msgid)} has an empty translation"
        end
      end
    end

    test "the Hex package ships priv/, where the catalogues live" do
      assert "priv" in Mix.Project.config()[:package][:files]
    end

    defp msgstr_texts(msgstr) when is_map(msgstr),
      do: Enum.map(msgstr, fn {_form, parts} -> IO.iodata_to_binary(parts) end)

    defp msgstr_texts(msgstr), do: [IO.iodata_to_binary(msgstr)]
  end

  describe "notify_channel/0" do
    test "returns the well-known LISTEN/NOTIFY channel" do
      assert PhoenixKitDb.notify_channel() == "phoenix_kit_db_changes"
    end
  end

  describe "fetch_row/3 — input validation (no DB required)" do
    # safe_qualified_table short-circuits BEFORE any RepoHelper call,
    # so these branches are reachable without a live Postgres.

    test "rejects schemas with unsafe characters" do
      assert {:error, :invalid_identifier} =
               PhoenixKitDb.fetch_row("schema-with-dashes", "users", 1)

      assert {:error, :invalid_identifier} =
               PhoenixKitDb.fetch_row("schema with spaces", "users", 1)

      assert {:error, :invalid_identifier} = PhoenixKitDb.fetch_row("a;b", "users", 1)
    end

    test "rejects tables with unsafe characters" do
      assert {:error, :invalid_identifier} =
               PhoenixKitDb.fetch_row("public", "table-with-dashes", 1)

      assert {:error, :invalid_identifier} =
               PhoenixKitDb.fetch_row("public", "table'); DROP TABLE x; --", 1)
    end

    test "rejects a name with a trailing newline" do
      assert {:error, :invalid_identifier} = PhoenixKitDb.fetch_row("public", "users\n", 1)
      assert {:error, :invalid_identifier} = PhoenixKitDb.fetch_row("public\n", "users", 1)
      assert {:error, :invalid_identifier} = PhoenixKitDb.ensure_trigger("public", "users\n")
      assert {:error, :invalid_identifier} = PhoenixKitDb.remove_trigger("public", "users\n")
    end

    test "rejects empty schema/table names" do
      assert {:error, :invalid_identifier} = PhoenixKitDb.fetch_row("", "users", 1)
      assert {:error, :invalid_identifier} = PhoenixKitDb.fetch_row("public", "", 1)
    end

    test "rejects non-integer non-UUID row_ids" do
      # parse_row_id returns nil for these, with shape pattern hits {:error, :invalid_id}.
      assert {:error, :invalid_id} =
               PhoenixKitDb.fetch_row("public", "users", "not-a-number-or-uuid")

      assert {:error, :invalid_id} = PhoenixKitDb.fetch_row("public", "users", nil)
      assert {:error, :invalid_id} = PhoenixKitDb.fetch_row("public", "users", :atom_id)
    end

    test "schema=nil falls back to public" do
      # We can verify the fallback by asserting it doesn't error on the
      # schema validation step — the row_id validation fires next.
      assert {:error, :invalid_id} = PhoenixKitDb.fetch_row(nil, "users", "not-id")
    end
  end

  describe "ensure_trigger/2 — input validation (no DB required)" do
    test "rejects unsafe schema or table names" do
      assert {:error, :invalid_identifier} = PhoenixKitDb.ensure_trigger("schema-bad", "users")
      assert {:error, :invalid_identifier} = PhoenixKitDb.ensure_trigger("public", "table; --")
      assert {:error, :invalid_identifier} = PhoenixKitDb.ensure_trigger("", "")
    end
  end

  describe "remove_trigger/2 — input validation (no DB required)" do
    test "rejects unsafe schema or table names" do
      assert {:error, :invalid_identifier} = PhoenixKitDb.remove_trigger("bad-schema", "users")
      assert {:error, :invalid_identifier} = PhoenixKitDb.remove_trigger("public", "bad-table")
    end
  end
end
