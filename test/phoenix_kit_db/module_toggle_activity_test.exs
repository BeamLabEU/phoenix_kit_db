defmodule PhoenixKitDb.ModuleToggleActivityTest do
  @moduledoc """
  Turning the module on or off leaves an activity entry under the `"db"`
  module key, logged through core's `PhoenixKit.Activity.log/3`.
  """
  use PhoenixKitDb.DataCase, async: false

  test "enable and disable are each logged under the db module" do
    PhoenixKitDb.enable_system()
    PhoenixKitDb.disable_system()

    for action <- ["db.module_enabled", "db.module_disabled"] do
      row = assert_activity_logged(action)
      assert row.module == "db"
      assert row.resource_type == "module"
    end
  end
end
