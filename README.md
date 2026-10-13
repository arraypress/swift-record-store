# RecordStore

Schema-checked records in SQLite, with shapes defined at run time. Give it a schema — fields with types — and it becomes a real table; records are checked against it on the way in, money is exact, every write is journalled and can be undone. Foundation and the system SQLite only: macOS 14+, iOS 17+.

It is the engine behind the [`store`](https://github.com/arraypress/swift-store-cli) command-line tool, where an agent defines a collection ("expenses") the moment it needs one and queries it later.

```swift
import RecordStore

let store = try RecordStore(path: "/path/to/main.sqlite")

try store.define(Schema.parse("""
    {"name": "expenses", "fields": [
        "shop:text!", "total:money(GBP)!", "date:date!",
        "category:choice(groceries|fuel|eating out)", "tags:tags"
    ]}
    """))

try store.add(["shop": .string("Tesco"), "total": .string("£23.40"), "date": .string("13 Oct 2026")], to: "expenses")

let october = try store.query("expenses", Query(
    filters: [try Filter.parse("category = groceries")],
    since: "2026-10-01",
    aggregates: [.sum("total")],
    groupBy: [.period(.week)]))

try store.undo()   // the last write, exactly reversed
```

## Field types

| Type | Stored as | Accepts |
|---|---|---|
| `text` | TEXT | strings (numbers become their text) |
| `number` | REAL | numbers, numeric strings |
| `integer` | INTEGER | whole numbers |
| `money` | INTEGER minor units + `<field>__currency` | `"23.40 GBP"`, `"GBP 23.40"`, `"£23.40"`, `"-€5"`, `"(12.00) USD"`, `"1,234.56"` / `7.25` (with the field's currency), `{"amount", "currency"}`, `{"minor", "currency"}` |
| `date` | TEXT `YYYY-MM-DD` | ISO, `2026/10/3`, `20261013`, `13 Oct 2026`, `October 13, 2026`, `today`, `yesterday`, unambiguous `25/12/2026` |
| `datetime` | TEXT UTC `YYYY-MM-DDTHH:MM:SSZ` | ISO with or without an offset (read in `timeZone`), `now` |
| `bool` | INTEGER 0/1 | `true`/`false`, `yes`/`no`, `1`/`0` |
| `choice` | TEXT | one of the field's `choices`, any case — stored in the declared spelling |
| `tags` | TEXT JSON array | an array of strings or `"a, b"`; trimmed, de-duplicated |

Fields take `required`, `default`, `unique`, `description`; `choices` for a choice field, `currency` for a money field. The shorthand `name:type` adds `!` for required, `(GBP)` or `(a|b|c)` for the argument, and `=value` for a default.

## What it refuses, and why

- **Money is never a float.** Amounts go through `Decimal` into integer minor units; `0.10 + 0.20` sums to exactly `0.30`. An amount finer than the currency allows (`"23.456 GBP"`, `"JPY 500.5"`) is refused rather than rounded. `$`, `¥` and `kr` name several currencies, so they are accepted only when the field's currency is one of them.
- **Sums never cross currencies.** Money aggregates are grouped by currency, so GBP and EUR come back as two rows.
- **Ambiguous dates are refused.** `03/04/2026` could be March or April; write `2026-04-03`. `25/12/2026` is unambiguous and accepted.
- **Unknown fields are refused**, so a misspelt key (`"shoop"`) is an error, not a silently dropped value.
- **A batch is all or nothing** (`addAll`): every problem is listed and nothing is stored.
- **Duplicates by source:** a record carries its source file's SHA-256; the same file added twice is refused unless `allowDuplicate`. `unique` fields are enforced with an index.

## Queries

`Query` holds filters (`field op value`: `= != < <= > >= ~ in`, values read as the field's type, `null` for empty), an inclusive `since`/`until` on the date field, aggregates (`count`, `sum`, `average`, `minimum`, `maximum`), groupings (a field, or `day`/`week`/`month`/`year` of the date field), a `running` total, ordering and a limit. Running totals accumulate per currency, over records in date order or over groups. Weeks are Monday-started weeks of the year (`2026-W40`), which every SQLite an app might ship supports.

## Undo

Every `define`, `add`, `update`, `delete` and `migrate` writes an exact before/after snapshot to `_store_journal`. `undo()` reverses the newest entry not yet undone — but first proves the target is still in the state the entry left it in, so a later change is never clobbered. An undone entry cannot be undone twice. Undoing a delete restores the record with its original id; undoing a dropped field restores its values.

## Raw SQL

`readOnlySQL` runs one statement through a connection opened read-only: SQLite itself refuses writes, and anything after the first statement is refused too. Collections are tables of the same name; the store's own tables are `_store_schemas` and `_store_journal`.

## Tests

30 tests (swift-testing): money edge cases (`"1,234.56"`, `"€5"`, refunds, `"JPY 500"`, ambiguous symbols, precision), dates, schema validation messages, exact per-currency sums, grouped and running totals, every undo path, migrations, and read-only SQL refusing five kinds of write.

## License

MIT — see [LICENSE](LICENSE).
