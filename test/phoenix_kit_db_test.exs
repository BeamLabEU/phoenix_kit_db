defmodule PhoenixKitDbTest do
  use ExUnit.Case

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

    test "enabled?/0 returns a boolean" do
      # In test env without DB this returns false (the rescue fallback).
      assert is_boolean(PhoenixKitDb.enabled?())
    end

    test "enable_system/0 is exported" do
      assert function_exported?(PhoenixKitDb, :enable_system, 0)
    end

    test "disable_system/0 is exported" do
      assert function_exported?(PhoenixKitDb, :disable_system, 0)
    end
  end

  describe "permission_metadata/0" do
    test "returns a map with required fields" do
      meta = PhoenixKitDb.permission_metadata()
      assert %{key: key, label: label, icon: icon, description: desc} = meta
      assert is_binary(key)
      assert is_binary(label)
      assert is_binary(icon)
      assert is_binary(desc)
    end

    test "key matches module_key" do
      meta = PhoenixKitDb.permission_metadata()
      assert meta.key == PhoenixKitDb.module_key()
    end

    test "icon uses hero- prefix" do
      meta = PhoenixKitDb.permission_metadata()
      assert String.starts_with?(meta.icon, "hero-")
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
      assert is_binary(main.path)
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
      version = PhoenixKitDb.version()
      assert is_binary(version)
      assert version == "0.1.0"
    end
  end

  describe "css_sources/0" do
    test "returns a list with the OTP app atom" do
      assert PhoenixKitDb.css_sources() == [:phoenix_kit_db]
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
      path = Paths.index()
      assert is_binary(path)
      assert String.ends_with?(path, "/admin/db")
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

  describe "notify_channel/0" do
    test "returns the well-known LISTEN/NOTIFY channel" do
      assert PhoenixKitDb.notify_channel() == "phoenix_kit_db_changes"
    end
  end
end
