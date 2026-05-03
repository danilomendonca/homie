# Homie — Home Inventory API

A JSON API for tracking household inventory. See `thoughts/prd.md` for the full product spec.

## Requirements

- Ruby 3.3+
- PostgreSQL 16+

## Setup

```sh
bin/setup
```

Environment variables (all optional in development — defaults shown):

| Variable | Default | Purpose |
|---|---|---|
| `HOMIE_DATABASE_HOST` | `localhost` | Postgres host |
| `HOMIE_DATABASE_PORT` | `5432` | Postgres port |
| `HOMIE_DATABASE_USERNAME` | `$USER` | Postgres user |
| `HOMIE_DATABASE_PASSWORD` | _(none)_ | Postgres password |
| `TZ` | `UTC` | Process timezone used for "today" calculations |

## Running specs

```sh
bundle exec rspec
```

## API

Base path: `/v1`

Swagger UI: `/v1/docs` (once OpenAPI generation is wired up in Phase 7)

## Notes

- Dockerfile/Kamal updates for Postgres are pending (not in Phase 1 scope).
- OpenAPI doc generation via `bundle exec rails rswag:specs:swaggerize` lands in Phase 7.
