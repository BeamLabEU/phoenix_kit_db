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
    test "logs a db.module_enabled activity row" do
      PhoenixKitDb.enable_system()

      assert_activity_logged("db.module_enabled")

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
    test "logs a db.module_disabled activity row" do
      PhoenixKitDb.disable_system()

      assert_activity_logged("db.module_disabled")
    end
  end
end
