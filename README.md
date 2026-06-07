# Homie — Home Inventory API

A JSON API for tracking household inventory: categories, products, and
per-batch inventory items, with aggregated stock, low-stock, and
near-expiration views. See `thoughts/prd.md` for the full product spec.

## Requirements

- Ruby 3.3+
- PostgreSQL 16+ (the `citext` extension and a native `unit_type` enum are
  used; both are provisioned by migrations)

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
| CRUD | `/v1/inventory_items`, `POST /v1/inventory_items/bulk` | Inventory batches (+ bulk upsert) |
| GET | `/v1/inventory` | Aggregated stock per product (`?include_empty=true` to include zero-quantity) |
| GET | `/v1/inventory/low_stock` | Products at/below their `low_stock_threshold` (strict `<`) |
| GET | `/v1/inventory/near_expiration` | Batches in `expired` and `near_expiration` buckets (`?days=N`, default 3) |

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
