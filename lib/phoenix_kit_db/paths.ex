defmodule PhoenixKitDb.Paths do
  @moduledoc """
  Centralized path helpers for the DB module.

  All paths route through `PhoenixKit.Utils.Routes.path/1` so the host
  app's URL prefix and current locale are applied automatically.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/db"

  @doc "Main DB landing page — list of tables with stats."
  @spec index() :: String.t()
  def index, do: Routes.path(@base)

  @doc "Live activity feed across all tables."
  @spec activity() :: String.t()
  def activity, do: Routes.path("#{@base}/activity")

  @doc "Detail / row preview page for a specific table."
  @spec show(String.t(), String.t()) :: String.t()
  def show(schema, table), do: Routes.path("#{@base}/#{schema}/#{table}")
end
