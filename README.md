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
| CRUD | `/v1/inventory_items`, `POST /v1/inventory_items/bulk` | Inventory batches (+ bulk upsert) |
| DELETE | `/v1/inventory_items` | Bulk reset — requires `?confirm=true`, optional `?product_id=` to scope; returns `{ "deleted": N }` |
| GET | `/v1/inventory` | Aggregated stock per product (`?include_empty=true` to include zero-quantity) |
| GET | `/v1/inventory/low_stock` | Products at/below their `low_stock_threshold` (strict `<`) |
| GET | `/v1/inventory/near_expiration` | Batches in `expired` and `near_expiration` buckets (`?days=N`, default 3) |
| POST | `/v1/inventory/import` | Receipt import — resolves parsed receipt lines against the catalogue and applies the stock in one call. See below |

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
