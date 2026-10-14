# RecordStore

Schema-checked records in SQLite, with shapes defined at run time — a small ORM. Give it a schema — fields with types — and it becomes a real table; records are checked against it on the way in, money is exact, records can be named by a key and linked to each other, and every write is journalled and can be undone. Foundation and the system SQLite only: macOS 14+, iOS 17+ (the iOS build is checked with `xcodebuild -scheme swift-record-store -destination 'generic/platform=iOS'`).

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

// A symptom noticed later, without restating the list (one journalled change):
try store.update(5, in: "meals", with: ["severity": .number(4)], adding: ["symptoms": ["stomach pain"]], removing: [:])

try store.undo()   // the last write, exactly reversed
```

Grouping by a `tags` field counts each record once under every tag it has (`groupBy: [.field("allergens")]`). A summary's order key may name a field with one aggregate (`total` → `total_sum`).

## Keys and links

```swift
try store.define(Schema.parse(#"{"name": "triggers", "key": "slug", "fields": ["label:text!", "kind:ref(trigger_kinds)!"]}"#))
try store.define(Schema.parse(#"{"name": "symptoms", "key": "slug", "fields": [
    "label:text!", "triggers:refs(triggers)", "onset_hours:range"]}"#))

try store.get("Dairy", from: "triggers")               // by key, without regard to case; "#12" is always an id
try store.update("bloating", in: "symptoms", with: [:], adding: ["triggers": ["gluten"]])
try store.delete("dairy", from: "triggers", force: true)   // takes the links to it out, in one undoable write
try store.query("symptoms", Query(filters: [Filter.parse("triggers ~ dairy")]))      // which symptoms list dairy?
try store.query("symptoms", Query(aggregates: [.count], groupBy: [.field("triggers.kind")]))
```

- **A key** (`Schema.key`) is a text field that names each record: required, unique without regard to case, never a bare number, `#…` or containing a comma (those read as ids or lists). `get`, `update`, `delete` and links take it; ids still work. A key named but not among the fields is added as the first field. `migrate(.setKey("name"))` gives a collection made before keys one, after checking every record has a distinct name.
- **`ref(c)` and `refs(c)`** link to one or several records of `c`, which must already exist (or be the collection itself). A link is stored as the target's key — or its id when the target has no key — in the target's own spelling, so the SQLite file reads like the catalogue it came from; `refs` are a JSON array like tags. A value naming no record is refused with the field and the reason. Deleting a record others link to is refused, naming them; with `force` the links are taken out first (an item leaves a `refs` list, an optional `ref` is cleared — a required `ref` still refuses), journalled with the delete as one batch that one `undo` reverses. A linked key cannot be changed, and undo refuses to strand a link (undoing the add of something now linked to, or the definition of a collection others link to).
- **Paths** follow links in filters (`category.label = Gut`, `triggers.kind = allergen`) and groupings (`.field("category.label")`). Through a list, a record counts once per group however many of its items share it. The reverse question — what links to dairy? — is a filter on the side holding the links (`triggers ~ dairy`); there is no back-reference syntax.
- **`range`** is a low–high pair of numbers (`[0.5, 3]`, `"0.5..3"`, `{"min", "max"}`), stored as two REAL columns; `~ 2` finds ranges containing 2.
- **Keyed files**: `schema.keyedRecords(in:under:)` reads `{"triggers": {"dairy": {…}}, "version": "1.1"}` (or the bare map) as records keyed by member name — the reading whose records name the schema's fields wins. `addAll(labelled:)` names each record by its key in problems; `merge(_:into:)` brings a keyed collection up to date from a newer copy (new keys added, given fields set, nothing removed, unchanged records untouched).
- **`check(requireLinked:)`** finds what slipped past the writes — an app writing the file directly: links to nothing, missing or repeated keys, empty required fields, SQLite's `quick_check`, and records of the named collections that nothing links to.

## What came before

```swift
let analysis = try store.window(WindowSpec(
    events: "symptom_log", exposures: "meals",
    within: .field("symptom.onset_hours", unit: 3600),     // or .fixed(from: 1800, to: 10_800)
    tally: ["foods", "foods.allergens"]))
```

For each event (a datetime record), the exposures whose datetime falls in the window before it. Each value of a tallied field gets: `events` and `events_share` (events with it in their window), `matched_share` (of exposures in any window, how many had it), `all_share` (of every exposure in the period) and `ratio = matched_share / all_share`. **The ratio is the point**: a value in every meal precedes every symptom and scores 1 — it is merely common; above 1 it turns up before events more than it turns up at all. A window is fixed or read per event from a `range` field it reaches (through a list of links, the widest). Strings are told apart without regard to case. **This is co-occurrence, not cause**, and small counts mislead — read `events` before `ratio`. Nothing in it knows about food.

## Reports

`report(_:_:)` assembles a `ReportSpec` — filters, a period (`since`/`until`, or `last: "90d"` ending today), averages and sums, top values of fields or paths, an optional "what came before" section, the log's columns — into a `Report`; `report.markdown()` sets it as Markdown with YAML front matter (title, period, date) that the fleet's `press` turns into a PDF. Specs can be saved with the schema (`migrate(.saveReport(spec))`) and run by name (`report(_:saved:)`); undo removes one. Datetimes in the log are shown in the store's time zone.

## Reading records into Swift types

```swift
struct Symptom: StoredRecord { static let collection = "symptoms"; var id: Int64; var slug: String; var triggers: [String]? … }
let symptoms = try store.fetch(Symptom.self, Query(filters: [Filter.parse("triggers ~ dairy")]))
```

`swiftSource(for:)` writes that struct for a collection (what `store schema NAME --emit swift` prints): optional unless required, CodingKeys for snake_case, choices as nested enums, money as `Money`, datetimes as `Date`, links as keys (`String`) or ids (`Int64`). So an app reads the very file the CLI writes, through this library.

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
| `ref(c)` | the target's key (or id) | a key in any case, an id, `"#id"` — must name a record of `c` |
| `refs(c)` | TEXT JSON array of keys (or ids) | an array or `"a, b"`; each must name a record of `c` |
| `range` | two REAL columns, `<field>` and `<field>__max` | `[0.5, 3]`, `"0.5..3"`, `"1 to 2"`, `{"min", "max"}`, one number |

Fields take `required`, `default`, `unique`, `description`; `choices` for a choice field, `currency` for a money field, `target` for a link. The shorthand `name:type` adds `!` for required, `(GBP)`, `(a|b|c)` (or `a,b,c` when no option holds a comma) or `(collection)` for the argument, and `=value` for a default; an object field's `type` may use the same `ref(triggers)` form.

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

Every `define`, `add`, `update`, `delete` and `migrate` writes an exact before/after snapshot to `_store_journal`. `undo()` reverses the newest entry not yet undone — but first proves the target is still in the state the entry left it in, so a later change is never clobbered. An undone entry cannot be undone twice. Undoing a delete restores the record with its original id; undoing a dropped field restores its values. Entries written by one operation share a `batch` and are undone together, newest first: an `addAll` (an import), a `merge`, a forced delete and the links it took out. (Before 0.2, `undo` after `addAll` took out only its last record.)

## Databases written by 0.1

They open and keep working: their schemas have no key and no links, and the journal gains a nullable `batch` column the first time 0.2 opens the file — the only change made to it. Verified by a test that opens a database written by `store` 0.1.1 (library 0.1.2), reads it, undoes its last old journal entry, adds to it, gives a collection a key and passes `check()`.

## Raw SQL

`readOnlySQL` runs one statement through a connection opened read-only: SQLite itself refuses writes, and anything after the first statement is refused too. Collections are tables of the same name; the store's own tables are `_store_schemas` and `_store_journal`.

## Tests

58 tests (swift-testing): money edge cases (`"1,234.56"`, `"€5"`, refunds, `"JPY 500"`, ambiguous symbols, precision), dates, schema validation messages, exact per-currency sums, grouped and running totals, every undo path, migrations, read-only SQL refusing five kinds of write — and, over a made-up catalogue: keys (case, numbers, trimming, set-key on old data), keyed files (three readings, a mismatched key), merge, dangling links refused at every write, forced deletes undone exactly, stranded-link undo refused, `check` finding hand-edited rows and unlinked records, filters and groups through paths (a record counted once per group), ranges, a diary with a known answer for the window (an ingredient in every meal scores exactly 1, the rare culprit 5.5), per-record windows through a link, reports (Markdown, saved specs, `last`), codegen decoding real records, and the 0.1 database fixture.

## License

MIT — see [LICENSE](LICENSE).
