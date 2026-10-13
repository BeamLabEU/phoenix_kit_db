# Dialyzer warnings to ignore (matched by dialyxir).
#
# Gettext 1.0 + Expo 1.1 generate a `Gettext.Plural.plural/2` call against Expo's
# *opaque* `PluralForms` struct inside the generated backend (`use Gettext.Backend`),
# which Dialyzer reports as `call_without_opaque` at `gettext.ex:1`. It is an
# upstream false positive in code this module does not author, so the skip is
# scoped to the backend module and that one warning type and real issues
# elsewhere still surface. The other `phoenix_kit_*` packages that carry their
# own Gettext backend skip the same warning the same way.
[
  {"lib/phoenix_kit_db/gettext.ex", :call_without_opaque}
]
