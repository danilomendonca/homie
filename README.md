# Homie — Home Inventory API

A JSON API for tracking household inventory: categories, products, and
per-batch inventory items, with aggregated stock, low-stock, and
near-expiration views. See `thoughts/prd.md` for the full product spec.

## Requirements

- Ruby 3.3+
- PostgreSQL 16+ (the `citext`, `pgcrypto`, `pg_trgm` and `unaccent` extensions
  and a native `unit_type` enum are used; all are provisioned by migrations, so
  there is no manual DBA step)

## Setup

A Postgres instance is provided via `docker-compose.yml` (Postgres 18, exposed
on host port **5433**, user/password `homie`/`homie`):

```sh
docker compose up -d   # start Postgres (auto-restarts unless stopped)
bin/setup              # install gems, create + migrate the database
```

If you point at that container, export the matching env vars before any
`bin/rails` or `rspec` command:

```sh
export HOMIE_DATABASE_HOST=127.0.0.1
export HOMIE_DATABASE_PORT=5433
export HOMIE_DATABASE_USERNAME=homie
export HOMIE_DATABASE_PASSWORD=homie
```

## Configuration

All variables are optional in development — defaults shown.

| Variable | Default | Purpose |
|---|---|---|
| `HOMIE_DATABASE_HOST` | `localhost` | Postgres host |
| `HOMIE_DATABASE_PORT` | `5432` | Postgres port |
| `HOMIE_DATABASE_USERNAME` | `$USER` | Postgres user |
| `HOMIE_DATABASE_PASSWORD` | _(none)_ | Postgres password |
| `TZ` | `UTC` | Process timezone. Controls what counts as "today" for the POST-time expiration-date validation and the `near_expiration` window (PRD §8.0, §15). |

## Running specs

```sh
bundle exec rspec
```

With the Docker Postgres container, prefix (or export, as above):

```sh
HOMIE_DATABASE_HOST=127.0.0.1 HOMIE_DATABASE_PORT=5433 \
HOMIE_DATABASE_USERNAME=homie HOMIE_DATABASE_PASSWORD=homie \
bundle exec rspec
```

## API surface

- **Base path:** `/v1`
- **Docs UI (Swagger):** `/v1/docs`
- **Machine-readable contract (OpenAPI 3):** `/v1/openapi.json`

Endpoints:

| Method | Path | Description |
|---|---|---|
| CRUD | `/v1/categories` | Categories |
| CRUD | `/v1/products`, `POST /v1/products/bulk` | Products (+ bulk create) |
| GET | `/v1/products/search` | Fuzzy (trigram) match on name **and** brand — `?q=` required, `?min_similarity=` (default 0.3), `?limit=` (default 20, max 100). Returns `similarity`, `name_similarity`, `brand_similarity` per hit |
| CRUD | `/v1/product_aliases` | Learned store-abbreviation → product map. `?store_name=` and `?product_id=` filter `index` (the store filter is exact — it does not include inherited wildcards). `store_name: null` is the wildcard tier that applies to every store; `(abbreviation, store_name)` is unique case-insensitively, wildcard included |
| GET | `/v1/product_aliases/lookup` | Exact (case-insensitive) resolution of one abbreviation — `?abbreviation=` required, `?store_name=` optional. A store-specific alias beats the wildcard; 404 when nothing matches. No fuzzy fallback — that is `/v1/products/search` |
| CRUD | `/v1/inventory_items`, `POST /v1/inventory_items/bulk` | Inventory batches (+ bulk upsert). `POST` is additive — undated writes go to the product's default batch, dated ones to the batch with that date (`201` created / `200` grown). See below |
| DELETE | `/v1/inventory_items` | Bulk reset — requires `?confirm=true`, optional `?product_id=` to scope; returns `{ "deleted": N }` |
| GET | `/v1/inventory` | Aggregated stock per product (`?include_empty=true` to include zero-quantity) |
| GET | `/v1/inventory/low_stock` | Products at/below their `low_stock_threshold` (strict `<`) |
| GET | `/v1/inventory/near_expiration` | Batches in `expired` and `near_expiration` buckets (`?days=N`, default 3) |
| POST | `/v1/inventory/import` | Receipt import — resolves parsed receipt lines against the catalogue and applies the stock in one call. See below |
| GET | `/v1/inventory/sample` | Products most overdue for a stock count, least-recently-verified first — `?limit=` (default 20, max 100). See below |
| POST | `/v1/inventory/verify` | Writes counted stock levels back, reconciling each count against the product's batches and stamping `stock_verified_at`. See below |
| POST | `/v1/inventory/consume` | Removes a quantity per product, draining FEFO across its batches (default batch last), without naming a batch. Returns each product's remaining `total_quantity`. **Not idempotent.** See below |

## Default batch & consumption

Batches and expiration dates are an optional refinement. Every product has at
most one **default batch** — its single `expiration_date: null` row, enforced by
a partial unique index — and every write that leaves out a date lands there.

`POST /v1/inventory_items` is additive and follows the same rule as a
one-element `POST /v1/inventory_items/bulk`:

- no `expiration_date` (omitted or `null`) → grows the default batch, creating it
  if absent;
- an `expiration_date` → grows the batch with that exact date, or creates one.

It answers `201` when a batch was created and `200` when an existing one grew;
the body is the batch either way. An unparseable `expiration_date` (`"soon"`,
`"2026-13-45"`) is a 422 rather than a silent fall-through to the default batch —
the same holds for `bulk`, `import` and `PATCH`. A `PATCH` that clears
`expiration_date` on a dated batch is a 422 when the product already has a
default batch.

`POST /v1/inventory/consume` removes stock by product:

```jsonc
{
  "items": [                    // required, max 500
    { "product_id": "…", "quantity": 500 }   // quantity > 0
  ]
}
```

- It drains **FEFO** — earliest expiration first, expired batches included, the
  default batch last — and deletes every batch of a touched product that ends at
  zero.
- Lines naming the same product are **summed**: two consumption events are two
  facts (unlike `verify`, where two counts are ambiguous).
- Consuming **more than the stock on hand is a per-index 422** on every line
  naming that product, with the stock on hand in the message. It never clamps:
  the mismatch is drift, and `POST /v1/inventory/verify` is the call that
  corrects it.
- It does **not** touch `stock_verified_at` — using stock does not confirm a count.
- The response is `{ "consumed": [{ "product_id": "…", "total_quantity": 3.0 }] }`,
  one entry per distinct product in request order.
- **Not idempotent** (PRD §15): a retried request removes the stock twice. Read
  `GET /v1/inventory` before retrying after a timeout.

## Receipt import

`POST /v1/inventory/import` takes already-parsed receipt lines (NF-e XML and OCR
parsing are the caller's job) and does the catalogue lookup server-side, so
entering a shopping trip is one request instead of three plus per-line guessing:

```jsonc
{
  "store_name": "Oba",          // optional — selects store-specific aliases
  "dry_run": true,              // optional, default false
  "create_unknown": false,      // optional, default false
  "auto_match_threshold": 0.6,  // optional, default 0.6, must be in (0, 1]
  "items": [                    // required, max 500
    { "name": "REFRIG COCA COLA 2L PET", "quantity": 1,
      "expiration_date": "2026-09-01", "brand": "Coca-Cola",
      "unit_type": "volume", "category_id": "…" }
  ]
}
```

Each line is resolved in order, first hit winning:

1. **Exact product name** (case- and accent-insensitive `citext`).
2. **Product alias**, with a store-specific alias beating the wildcard — the same
   precedence as `/v1/product_aliases/lookup`.
3. **Trigram similarity** over accent-stripped name and brand, at or above
   `auto_match_threshold`.

The similarity step is the only probabilistic one, and it is guarded. A matching
brand scores `1.000` on the combined score no matter which SKU it is, so a bare
threshold test cannot tell three Coca-Cola sizes apart. When more than one
product clears the threshold, the top candidate must lead the runner-up by at
least `0.05` on `name_similarity`; otherwise the line comes back as `unmatched`
with `reason: "ambiguous_match"` rather than adding 2 litres to a coin flip.

The response partitions every line into `matched`, `created`, and `unmatched`,
each entry echoing its `index` and raw `input`. **Unmatched lines are not
errors** — they are reported with up to five scored `suggestions` and skipped,
and the request still returns 200. Only validation failures produce the 422
per-index `failed` envelope, and they roll the entire import back.

- `dry_run: true` previews the partitioning without writing. `applied` is then
  `false` and every `inventory_item` — plus every `created` entry's `product` —
  is `null`, because nothing was persisted and a transient id would 404 on the
  next request. `dry_run` and `create_unknown` are parsed strictly: anything
  other than `true`/`false` is a 400, so a typo cannot silently persist a
  preview.
- `create_unknown: true` creates a product for an unresolved line. That line must
  carry `unit_type` — the unit-type decision is a human one, and guessing it
  would corrupt the catalogue — otherwise the line stays `unmatched` with
  `reason: "missing_unit_type"`. Two lines naming the same new product create one
  product with the quantities merged.
- Matched stock is applied through the same additive path as
  `POST /v1/inventory_items/bulk`: lines are grouped by
  `(product_id, expiration_date)` and merged into the oldest matching batch, or a
  new batch is created.
- **Not idempotent** (PRD §15): re-posting the same receipt adds the quantities
  again. There are no idempotency keys.

The fix for an unmatched line is the learning loop: dry-run the receipt, pick the
right product, `POST /v1/product_aliases`, re-import — the line then resolves
with `match_source: "alias"`. There is deliberately no per-line `product_id`
override; a genuine one-off goes through `POST /v1/inventory_items/bulk`.

## Stock verification

Entering stock is one call, but nothing corrects the drift between what the API
believes and what is on the shelf — and every downstream signal (low-stock
alerts, grocery lists, recipe deltas) inherits that error. Two endpoints close
the loop around one column, `products.stock_verified_at`.

`GET /v1/inventory/sample` answers "which products are most overdue for a
count?". It orders by `stock_verified_at ASC NULLS FIRST` — never-verified
products lead, then oldest first — with the pt-BR collation on the product name
as the tiebreak, and returns `total_quantity` and `low_stock_threshold` per row
so the caller can pose the question and check the answer without a second
request. **Every product is a candidate**, including ones with no batches and
ones whose batches sum to zero: "did I actually run out of rice?" is exactly what
a count answers, and `/v1/inventory` cannot ask it. There is no `batches` array —
two batches differing only by `expiration_date` are indistinguishable on a shelf,
so a per-batch question is unanswerable.

`POST /v1/inventory/verify` writes the answers back:

```jsonc
{
  "items": [                    // required, max 500
    { "product_id": "…", "quantity": 3 }
  ]
}
```

**The counted quantity is absolute, not a delta**, and it is reconciled against
the product's batches:

- **Decrease** — drain FEFO: earliest expiration first, undated batches last.
  Any batch left at zero is deleted, so no dead row survives for
  `?include_empty=true` to report. Draining an *expired* batch works: the
  past-date rule is create-context only, and counting down a product whose stock
  went bad is exactly when verification is most needed.
- **Increase** — the difference lands in the product's **undated**
  (`expiration_date: null`) batch, creating it if the product has none. An
  increase means an unrecorded purchase whose date is unknown; merging it into a
  dated batch would make `near_expiration` report the newly counted stock as
  expiring on the strength of a guess, or — when the only batches are expired —
  as already expired. A product holds at most one undated batch (a partial
  unique index guarantees it), so there is never a choice to make.
- **Zero** — every batch for the product is deleted.

**The timestamp advances even when the count was already correct.** That is the
load-bearing rule, not an implementation detail: without it a product that is
always right is indistinguishable from one that has never been counted, and the
sample re-surfaces it forever.

A **partial reply is the normal case** — answer some of the sampled products and
ignore the rest. Only the products in the body are touched; the others keep their
old timestamp and stay at the front of the next sample. The request is
all-or-nothing, though: any per-index failure (unknown or duplicated
`product_id`, a bad quantity, a fractional count on a `unit_type: unit` product)
returns the 422 `failed` envelope and rolls the whole thing back. An unknown
`product_id` is a per-index failure, never a top-level 404 — a 404 cannot say
which of twenty lines was bad.

The response is `{ "verified": N }`, counting every product in the body including
the unchanged ones; the follow-up read is `GET /v1/inventory`.
`POST /v1/inventory/verify` is the only writer of `stock_verified_at` — a
`PATCH /v1/products/:id` carrying it is ignored.

## Regenerating the OpenAPI doc

The contract is generated from the rswag request specs and committed at
`swagger/openapi.json` (served at `/v1/openapi.json`). Regenerate and commit it
whenever a request spec or `spec/swagger_helper.rb` changes:

```sh
bundle exec rails rswag
```

`spec/requests/api/v1/openapi_contract_spec.rb` is a drift guard: it replays a
real request per resource and asserts the live response matches the committed
schema, so a stale `swagger/openapi.json` fails CI.

## Seed data

```sh
bin/rails db:seed
```

Loads an idempotent, mixed-state fixture (re-runnable without duplicating
rows): seven products across four categories with batches covering in-stock,
low-stock, expired, near-expiration, no-expiration, and fully-consumed
(zero-quantity) states — enough to exercise every endpoint's interesting
branch.

## Smoke check

With a seeded database and the server running (`bin/rails s`), hit every
endpoint and pretty-print the responses:

```sh
BASE=http://localhost:3000 script/smoke.sh
```
