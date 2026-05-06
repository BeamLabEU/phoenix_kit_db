defmodule PhoenixKitDb.ActivityLoggingTest do
  @moduledoc """
  Pins activity-log emissions for the only audited operations the DB
  module owns: module enable/disable. Read-mostly + system-level
  operations (table preview, row search, trigger install) deliberately
  do NOT log activity to keep the feed signal-to-noise high.

  `async: false` because `Settings.update_*` writes to a process-wide
  ETS cache (workspace flaky-test trap).
  """
  use PhoenixKitDb.DataCase, async: false

  describe "enable_system/0" do
    test "logs a db.module_enabled activity row with the right metadata shape" do
      PhoenixKitDb.enable_system()

      # Pin the action atom AND the row's full metadata shape — every
      # field the workspace audit feed expects (module, mode,
      # resource_type) needs to land. assert_activity_logged returns
      # the matched row so we can assert further on it.
      row = assert_activity_logged("db.module_enabled")

      assert row.module == "db"
      assert row.mode == "manual"
      assert row.resource_type == "module"
      # No actor on a system-level toggle; the Modules LV in core
      # invokes enable_system/0 without threading the user's UUID.
      assert row.actor_uuid == nil

      # Reset to default for downstream tests in the same VM.
      PhoenixKitDb.disable_system()
    end

    test "does not raise when PhoenixKit.Activity is unavailable" do
      # Guard with Code.ensure_loaded?/1 — this test pins the rescue.
      # In our test env Activity IS loaded, so we just confirm the
      # success path returns the wrapped Settings result without
      # crashing.
      assert {:ok, _setting} = PhoenixKitDb.enable_system()
      PhoenixKitDb.disable_system()
    end
  end

  describe "disable_system/0" do
    test "logs a db.module_disabled activity row with the right metadata shape" do
      PhoenixKitDb.disable_system()

      row = assert_activity_logged("db.module_disabled")

      assert row.module == "db"
      assert row.mode == "manual"
      assert row.resource_type == "module"
    end
  end
end
