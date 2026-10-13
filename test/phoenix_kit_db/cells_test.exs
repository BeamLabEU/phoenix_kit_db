defmodule PhoenixKitDb.CellsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDb.Cells

  defmodule Opaque do
    @moduledoc false
    defstruct [:inner]
  end

  describe "secret_column?/1" do
    @masked ~w(
      password PASSWORD Password user_password password_confirmation passwd
      hashed_password secret webhook_secret api_secret secret_access_key client_secret
      token TOKEN access_token refresh_token auth_token reset_token token_expires_at
      api_key API_KEY apikey ApiKey private_key credential credentials aws_credentials
      salt password_salt content_hash file_hash hashed_token encrypted_value
      encrypted_data access_key passphrase pwd PWD signing_key encryption_key auth_key
    )

    @shown ~w(
      id uuid email name key value hash hashes hash_algorithm status inserted_at
      updated_at description title user_uuid pass passed public_key_id note
      crypted position
    )

    for name <- @masked do
      test "masks #{name}" do
        assert Cells.secret_column?(unquote(name))
      end
    end

    for name <- @shown do
      test "shows #{name}" do
        refute Cells.secret_column?(unquote(name))
      end
    end

    test "accepts atom names and rejects anything that is not a name" do
      assert Cells.secret_column?(:api_key)
      refute Cells.secret_column?(:email)
      refute Cells.secret_column?(nil)
      refute Cells.secret_column?(42)
    end
  end

  describe "sanitize_row/2" do
    test "uppercase key/value columns follow the same masking and search rule" do
      assert Cells.sanitize_row(%{"Key" => "signing_key", "Value" => "LEAK"}) == %{
               "Key" => "signing_key",
               "Value" => Cells.masked_placeholder()
             }

      refute Cells.searchable_column?("Value", ["Key", "Value"])
      refute Cells.searchable_column?("encryption_key", ["encryption_key"])
      assert Cells.searchable_column?("Value", ["Value"])
    end

    test "replaces every non-null secret value with the placeholder, whatever its type" do
      row = %{
        "hashed_password" => "LEAK-text",
        "api_key" => <<0xFF, 0xFE, 1, 2>>,
        "token" => 12_345,
        "secret" => %{"inner" => "LEAK-map"},
        "private_key" => ["LEAK-list"],
        "email" => "kept@example.com"
      }

      sanitized = Cells.sanitize_row(row)

      for column <- ~w(hashed_password api_key token secret private_key) do
        assert sanitized[column] == Cells.masked_placeholder()
      end

      assert sanitized["email"] == "kept@example.com"
      refute inspect(sanitized) =~ "LEAK"
    end

    test "a null secret stays null" do
      assert Cells.sanitize_row(%{"token" => nil, "note" => nil}) == %{
               "token" => nil,
               "note" => nil
             }
    end

    test "masks secret-named keys at any depth of a JSON value" do
      row = %{
        "settings" => %{
          "theme" => "dark",
          "smtp_password" => "LEAK-1",
          "providers" => [%{"name" => "s3", "secret_access_key" => "LEAK-2", "token" => nil}]
        }
      }

      assert Cells.sanitize_row(row) == %{
               "settings" => %{
                 "theme" => "dark",
                 "smtp_password" => Cells.masked_placeholder(),
                 "providers" => [
                   %{
                     "name" => "s3",
                     "secret_access_key" => Cells.masked_placeholder(),
                     "token" => nil
                   }
                 ]
               }
             }
    end

    test "decodes a uuid column to canonical text and leaves other 16-byte binaries alone" do
      raw = Ecto.UUID.dump!("018f3c1e-7a2b-7c3d-8e4f-5a6b7c8d9e0f")

      sanitized =
        Cells.sanitize_row(
          %{"uuid" => raw, "blob" => raw, "refs" => [raw, nil], "empty" => nil},
          %{"uuid" => :scalar, "refs" => :array, "empty" => :scalar}
        )

      assert sanitized["uuid"] == "018f3c1e-7a2b-7c3d-8e4f-5a6b7c8d9e0f"
      assert sanitized["blob"] == raw
      assert sanitized["refs"] == ["018f3c1e-7a2b-7c3d-8e4f-5a6b7c8d9e0f", nil]
      assert sanitized["empty"] == nil
    end
  end

  describe "format/2" do
    @texts [
      {nil, ""},
      {true, "true"},
      {false, "false"},
      {42, "42"},
      {1.5, "1.5"},
      {"plain", "plain"},
      {"", ""},
      {Decimal.new("1234.50"), "1234.50"},
      {Decimal.new("1E+3"), "1000"},
      {~D[2024-02-29], "2024-02-29"},
      {~T[13:14:15.000000], "13:14:15"},
      {~T[13:14:15.250000], "13:14:15.250000"},
      {~N[2024-02-29 13:14:15.000000], "2024-02-29 13:14:15"},
      {~U[2024-02-29 13:14:15.000000Z], "2024-02-29 13:14:15Z"},
      {%Postgrex.INET{address: {10, 1, 2, 3}, netmask: 32}, "10.1.2.3"},
      {%Postgrex.INET{address: {10, 1, 2, 3}, netmask: nil}, "10.1.2.3"},
      {%Postgrex.INET{address: {10, 0, 0, 0}, netmask: 8}, "10.0.0.0/8"},
      {%Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 1}, netmask: 128}, "::1"},
      {%Postgrex.INET{address: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, netmask: 32}, "2001:db8::/32"},
      {%Postgrex.MACADDR{address: {8, 0, 43, 1, 2, 3}}, "08:00:2b:01:02:03"},
      {%Postgrex.Interval{months: 14, days: 3, secs: 14_706, microsecs: 0},
       "1 year 2 mons 3 days 04:05:06"},
      {%Postgrex.Interval{months: 0, days: 0, secs: 0, microsecs: 0}, "00:00:00"},
      {%Postgrex.Interval{months: 0, days: 1, secs: 0, microsecs: 0}, "1 day"},
      {%Postgrex.Interval{months: 0, days: 0, secs: -90, microsecs: -500_000}, "-00:01:30.5"},
      {%Postgrex.Range{lower: 1, upper: 5, lower_inclusive: true, upper_inclusive: false},
       "[1,5)"},
      {%Postgrex.Range{lower: :empty, upper: :empty}, "empty"},
      {%Postgrex.Range{
         lower: ~D[2024-01-01],
         upper: :unbound,
         lower_inclusive: true,
         upper_inclusive: false
       }, "[2024-01-01,)"},
      {%Postgrex.Range{
         lower: :unbound,
         upper: Decimal.new("9.5"),
         lower_inclusive: false,
         upper_inclusive: true
       }, "(,9.5]"},
      {[1, 2, 3], "[1,2,3]"},
      {[], "[]"},
      {[~c"a", "b"], ~s([[97],"b"])},
      {%{"a" => %{"b" => [1, "x"]}}, ~s({"a":{"b":[1,"x"]}})},
      {%{}, "{}"},
      {<<0xDE, 0xAD, 0xBE, 0xEF>>, "\\xdeadbeef"},
      {{1, "a", nil}, "(1,a,)"},
      {:an_atom, ":an_atom"}
    ]

    for {{value, expected}, index} <- Enum.with_index(@texts) do
      test "known value ##{index} renders as #{inspect(expected)}" do
        assert Cells.format(unquote(Macro.escape(value))) == unquote(expected)
      end
    end

    test "a decimal and a timestamp are not wrapped in quotes" do
      refute Cells.format(Decimal.new("1.5")) =~ ~s(")
      refute Cells.format(~N[2024-02-29 13:14:15]) =~ ~s(")
    end

    test "a long non-text binary is cut to a preview with its size" do
      text = Cells.format(:binary.copy(<<0xFF>>, 1000))

      assert text == "\\x" <> String.duplicate("ff", 32) <> "… (1000 bytes)"
    end

    test "pretty: true indents JSON objects and arrays" do
      assert Cells.format(%{"a" => [1]}, pretty: true) == "{\n  \"a\": [\n    1\n  ]\n}"
    end

    test "an unknown struct renders as its inspect form" do
      assert Cells.format(%Opaque{inner: 1}) == inspect(%Opaque{inner: 1})
    end

    # Every value type in every position a row can put it in: bare, as an
    # array element, as a JSON value, nested one level further, as a tuple
    # field and as a range bound. `format/2` must hand back printable text for
    # all of them; a raise here is a dead page.
    test "the shape x type product always renders printable text" do
      types = [
        true,
        7,
        2.5,
        "text",
        <<0xFF, 0x00>>,
        Decimal.new("3.14"),
        ~D[2024-02-29],
        ~T[13:14:15],
        ~N[2024-02-29 13:14:15],
        ~U[2024-02-29 13:14:15Z],
        %Postgrex.INET{address: {127, 0, 0, 1}, netmask: 32},
        %Postgrex.INET{address: :not_an_address, netmask: 32},
        %Postgrex.MACADDR{address: {8, 0, 43, 1, 2, 3}},
        %Postgrex.Interval{months: 1, days: 2, secs: 3, microsecs: 4},
        %Postgrex.Interval{months: nil, days: nil, secs: nil, microsecs: nil},
        %Postgrex.Range{lower: 1, upper: 2, lower_inclusive: true, upper_inclusive: false},
        %Postgrex.Point{x: 1.0, y: 2.0},
        %Postgrex.Lexeme{word: "cat", positions: [{1, nil}]},
        %Opaque{inner: {:tuple, self(), make_ref(), &is_nil/1}},
        {1, 2},
        :atom,
        self(),
        [1, [2, [3]]],
        %{"k" => %{"k" => 1}},
        %{1 => :non_string_key, {:a, :b} => "tuple key", <<0xFF>> => "binary key"}
      ]

      shapes = [
        bare: & &1,
        array: &[&1, &1],
        json_value: &%{"key" => &1},
        nested: &%{"outer" => [%{"inner" => &1}]},
        tuple: &{&1, &1},
        range:
          &%Postgrex.Range{lower: &1, upper: &1, lower_inclusive: true, upper_inclusive: true}
      ]

      for {shape, wrap} <- shapes, type <- types, pretty <- [false, true] do
        text = Cells.format(wrap.(type), pretty: pretty)

        assert String.valid?(text) and text != "",
               "#{shape} over #{inspect(type, structs: false)} rendered #{inspect(text)}"
      end

      assert Cells.format(nil) == ""
      assert Cells.format([nil, nil]) == "[null,null]"
    end

    test "collection?/1 is true for JSON objects and arrays only" do
      assert Cells.collection?(%{"a" => 1})
      assert Cells.collection?([1])
      refute Cells.collection?(Decimal.new("1"))
      refute Cells.collection?(~N[2024-02-29 13:14:15])
      refute Cells.collection?("text")
      refute Cells.collection?(nil)
    end
  end

  describe "sanitize_row/2 on key/value rows" do
    test "a secret-named key masks the row's value columns" do
      row = %{
        "key" => "sync_incoming_password",
        "value" => "hunter2",
        "value_json" => %{"a" => 1}
      }

      assert %{"key" => "sync_incoming_password", "value" => masked, "value_json" => masked} =
               Cells.sanitize_row(row)

      assert masked == Cells.masked_placeholder()
    end

    test "a neutral key leaves the value alone, and a null value stays null" do
      assert %{"value" => "Europe/Tallinn"} =
               Cells.sanitize_row(%{"key" => "time_zone", "value" => "Europe/Tallinn"})

      assert %{"value" => nil} =
               Cells.sanitize_row(%{"name" => "aws_secret_access_key", "value" => nil})
    end

    test "a secret-looking name on a row without value columns changes nothing else" do
      assert %{"name" => "API token rotation", "status" => "done"} =
               Cells.sanitize_row(%{"name" => "API token rotation", "status" => "done"})
    end
  end
end
