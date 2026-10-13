defmodule PhoenixKitDb.Cells do
  @moduledoc """
  The one place a raw Postgres value becomes something a page may show.

  Two jobs, used by both the Show page and the Activity feed:

    * `sanitize_row/2` runs right after a query. It replaces every non-null
      value in a secret-named column with `masked_placeholder/0` and turns
      16-byte binaries from `uuid`-typed columns into canonical uuid text.
      Masking here, before the row reaches an assign, is what keeps a secret
      out of the rendered HTML, the LiveView state and every diff sent to the
      browser. Nothing downstream can leak what it never received.
    * `format/2` turns any term into display text. It is total: a value it
      does not know renders as its `inspect/1` form, never as an exception,
      because both pages call it while rendering rows of arbitrary tables and
      the Activity feed calls it from `handle_info/2`.

  Masking is by COLUMN NAME (and by key name inside JSON values), plus one
  row-level rule for key/value tables: a row whose `key` or `name` reads as a
  secret has its `value*` columns masked. A secret stored under a neutral name
  in any other shape is not recognised.
  """

  @placeholder "••••••"

  @secret_fragments ~w(
    password passwd passphrase secret token api_key apikey access_key
    private_key credential salt
  )
  @secret_prefixes ~w(hashed_ encrypted_)
  @secret_suffixes ~w(_hash)

  @key_columns ~w(key name)

  @binary_preview_bytes 32

  @typedoc "How a uuid-typed column stores its values: one uuid, or an array of them."
  @type uuid_kind :: :scalar | :array

  @doc "The fixed text shown in place of every masked value."
  @spec masked_placeholder() :: String.t()
  def masked_placeholder, do: @placeholder

  @doc """
  Whether a column (or JSON key) name marks its value as a secret.

  Case-insensitive. Matches a denylist of fragments anywhere in the name plus
  the `hashed_` / `encrypted_` prefixes and the `_hash` suffix. It deliberately
  over-matches (`salt` also hides `salted_at`): a masked harmless column costs
  a glance at `psql`, a shown secret cannot be taken back.
  """
  @spec secret_column?(term()) :: boolean()
  def secret_column?(name) when is_binary(name) do
    name = String.downcase(name)

    String.contains?(name, @secret_fragments) or
      String.starts_with?(name, @secret_prefixes) or
      String.ends_with?(name, @secret_suffixes)
  end

  def secret_column?(name) when is_atom(name) and not is_nil(name),
    do: secret_column?(Atom.to_string(name))

  def secret_column?(_name), do: false

  @doc """
  Masks secrets in a `%{column_name => value}` row and decodes its uuid columns.

  `uuid_kinds` maps the names of `uuid` / `uuid[]` columns to `:scalar` /
  `:array`; it comes from the catalog, so a 16-byte `bytea` value is never
  mistaken for a uuid. `nil` stays `nil` in every column, so a missing secret
  is still visibly missing.
  """
  @spec sanitize_row(map(), %{optional(String.t()) => uuid_kind()}) :: map()
  def sanitize_row(row, uuid_kinds \\ %{}) when is_map(row) do
    keyed_secret? = keyed_secret?(row)

    Map.new(row, fn {name, value} ->
      if keyed_secret? and value_column?(name) and not is_nil(value) do
        {name, @placeholder}
      else
        {name, sanitize_value(name, value, Map.get(uuid_kinds, name))}
      end
    end)
  end

  # Key/value tables (settings above all) keep the secret in a neutrally named
  # `value` column and say what it is in the row's own `key`. When that key
  # reads as a secret, the row's value columns are masked with it.
  defp keyed_secret?(row) do
    Enum.any?(@key_columns, fn column ->
      key = Map.get(row, column)
      is_binary(key) and secret_column?(key)
    end)
  end

  defp value_column?(name) when is_binary(name), do: String.starts_with?(name, "value")
  defp value_column?(_name), do: false

  defp sanitize_value(_name, nil, _kind), do: nil

  defp sanitize_value(name, value, kind) do
    if secret_column?(name) do
      @placeholder
    else
      value |> decode_uuid(kind) |> mask_nested()
    end
  end

  defp decode_uuid(<<_::128>> = raw, :scalar) do
    case Ecto.UUID.load(raw) do
      {:ok, text} -> text
      :error -> raw
    end
  end

  defp decode_uuid(values, :array) when is_list(values) do
    Enum.map(values, fn
      nested when is_list(nested) -> decode_uuid(nested, :array)
      value -> decode_uuid(value, :scalar)
    end)
  end

  defp decode_uuid(value, _kind), do: value

  # JSON columns carry secrets under keys of their own (`{"api_key": "…"}`),
  # so the same name rule applies to every key of a nested map.
  defp mask_nested(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, nested} ->
      if not is_nil(nested) and secret_column?(key) do
        {key, @placeholder}
      else
        {key, mask_nested(nested)}
      end
    end)
  end

  defp mask_nested(value) when is_list(value), do: Enum.map(value, &mask_nested/1)
  defp mask_nested(value), do: value

  @doc """
  Whether a value is a JSON object or an array, which the Activity feed
  folds away behind a disclosure instead of printing inline.
  """
  @spec collection?(term()) :: boolean()
  def collection?(value) when is_list(value), do: true
  def collection?(value) when is_map(value), do: not is_struct(value)
  def collection?(_value), do: false

  @doc """
  Display text for any value. Never raises.

  `nil` is `""`; the caller decides how a null is shown. `pretty: true`
  indents JSON objects and arrays.
  """
  @spec format(term(), keyword()) :: String.t()
  def format(value, opts \\ []) do
    do_format(value, Keyword.get(opts, :pretty, false) == true)
  rescue
    _ -> safe_inspect(value)
  catch
    _, _ -> safe_inspect(value)
  end

  defp do_format(nil, _pretty), do: ""
  defp do_format(value, _pretty) when is_boolean(value), do: to_string(value)
  defp do_format(value, _pretty) when is_integer(value), do: Integer.to_string(value)
  defp do_format(value, _pretty) when is_float(value), do: Float.to_string(value)
  defp do_format(value, _pretty) when is_binary(value), do: format_binary(value)

  # Structs are maps, so every struct clause sits above the plain-map one.
  defp do_format(%Decimal{} = value, _pretty), do: Decimal.to_string(value, :normal)
  defp do_format(%Date{} = value, _pretty), do: Date.to_iso8601(value)
  defp do_format(%Time{} = value, _pretty), do: value |> whole_second() |> Time.to_iso8601()

  defp do_format(%NaiveDateTime{} = value, _pretty),
    do: value |> whole_second() |> NaiveDateTime.to_string()

  defp do_format(%DateTime{} = value, _pretty),
    do: value |> whole_second() |> DateTime.to_string()

  defp do_format(%Postgrex.INET{} = value, _pretty), do: format_inet(value)
  defp do_format(%Postgrex.MACADDR{address: address}, _pretty), do: format_mac(address)
  defp do_format(%Postgrex.Interval{} = value, _pretty), do: format_interval(value)
  defp do_format(%Postgrex.Range{} = value, pretty), do: format_range(value, pretty)
  defp do_format(value, _pretty) when is_struct(value), do: safe_inspect(value)

  defp do_format(value, pretty) when is_map(value) or is_list(value) do
    Jason.encode!(json_term(value), pretty: pretty)
  end

  # Composite and row types arrive as tuples.
  defp do_format(value, pretty) when is_tuple(value) do
    inner = value |> Tuple.to_list() |> Enum.map_join(",", &do_format(&1, pretty))
    "(" <> inner <> ")"
  end

  defp do_format(value, _pretty), do: safe_inspect(value)

  # Postgres hands every time value over at microsecond precision; a whole
  # second reads better without six zeros after it.
  defp whole_second(%{microsecond: {0, _precision}} = value), do: %{value | microsecond: {0, 0}}
  defp whole_second(value), do: value

  defp format_binary(value) do
    cond do
      String.valid?(value) ->
        value

      byte_size(value) > @binary_preview_bytes ->
        head = binary_part(value, 0, @binary_preview_bytes)
        "\\x" <> Base.encode16(head, case: :lower) <> "… (#{byte_size(value)} bytes)"

      true ->
        "\\x" <> Base.encode16(value, case: :lower)
    end
  end

  defp format_inet(%Postgrex.INET{address: address, netmask: netmask}) do
    text = address |> :inet.ntoa() |> to_string()

    host_bits = if tuple_size(address) == 4, do: 32, else: 128

    if is_integer(netmask) and netmask != host_bits do
      "#{text}/#{netmask}"
    else
      text
    end
  end

  defp format_mac(address) when is_tuple(address) do
    address
    |> Tuple.to_list()
    |> Enum.map_join(":", fn byte ->
      byte |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
    end)
  end

  defp format_mac(address), do: safe_inspect(address)

  defp format_interval(%Postgrex.Interval{months: months, days: days, secs: secs} = interval) do
    microsecs = Map.get(interval, :microsecs) || 0

    dates =
      Enum.reject(
        [
          interval_unit(div(months, 12), "year"),
          interval_unit(rem(months, 12), "mon"),
          interval_unit(days, "day")
        ],
        &is_nil/1
      )

    clock =
      if secs != 0 or microsecs != 0 or dates == [],
        do: [interval_clock(secs, microsecs)],
        else: []

    Enum.join(dates ++ clock, " ")
  end

  defp interval_unit(0, _unit), do: nil
  defp interval_unit(count, unit) when count in [1, -1], do: "#{count} #{unit}"
  defp interval_unit(count, unit), do: "#{count} #{unit}s"

  defp interval_clock(secs, microsecs) do
    total = secs * 1_000_000 + microsecs
    sign = if total < 0, do: "-", else: ""
    total = abs(total)
    micro = rem(total, 1_000_000)
    seconds = div(total, 1_000_000)

    clock =
      Enum.map_join(
        [div(seconds, 3600), rem(div(seconds, 60), 60), rem(seconds, 60)],
        ":",
        fn n ->
          n |> Integer.to_string() |> String.pad_leading(2, "0")
        end
      )

    fraction =
      if micro == 0 do
        ""
      else
        "." <>
          (micro
           |> Integer.to_string()
           |> String.pad_leading(6, "0")
           |> String.trim_trailing("0"))
      end

    sign <> clock <> fraction
  end

  defp format_range(%Postgrex.Range{lower: :empty}, _pretty), do: "empty"
  defp format_range(%Postgrex.Range{upper: :empty}, _pretty), do: "empty"

  defp format_range(%Postgrex.Range{} = range, pretty) do
    open = if range.lower_inclusive, do: "[", else: "("
    close = if range.upper_inclusive, do: "]", else: ")"

    open <> range_bound(range.lower, pretty) <> "," <> range_bound(range.upper, pretty) <> close
  end

  defp range_bound(bound, _pretty) when bound in [nil, :unbound], do: ""
  defp range_bound(bound, pretty), do: do_format(bound, pretty)

  # Reduces a decoded JSON value, or a Postgres array, to something Jason can
  # always encode: scalars it knows stay as they are and everything else
  # becomes its display text.
  defp json_term(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, nested} -> {json_key(key), json_term(nested)} end)
  end

  defp json_term(value) when is_list(value), do: Enum.map(value, &json_term/1)
  defp json_term(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp json_term(value), do: do_format(value, false)

  defp json_key(key) when is_binary(key), do: format_binary(key)
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: do_format(key, false)

  # `inspect/2` is the last resort and must not raise either: a struct whose
  # Inspect implementation is broken falls back to its bare map form.
  defp safe_inspect(value) do
    inspect(value)
  rescue
    _ -> inspect(value, structs: false)
  catch
    _, _ -> inspect(value, structs: false)
  end
end
