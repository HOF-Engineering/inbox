# SETUP_GUIDE.md — HOF Immigration (Chatwoot fork)

Local development setup for this Chatwoot fork. Everything below is derived from
`Gemfile`, `package.json`, `Procfile.dev`, `.env.example`, and `config/` in this repo.

---

## 1. Required versions

| Tool | Version | Source of truth |
|------|---------|-----------------|
| Ruby | **3.4.4** | `Gemfile` (`ruby '3.4.4'`) / `.ruby-version` |
| Rails | **~7.1** | `Gemfile` (`gem 'rails', '~> 7.1'`) |
| Node | **24.x** | `package.json` → `engines.node` |
| pnpm | **10.x** (pinned `10.2.0`) | `package.json` → `engines.pnpm` / `packageManager` |
| PostgreSQL | **13+** (needs `pgvector` extension) | `pg`, `pgvector`, `neighbor` gems; `vector` column in `db/schema.rb` |
| Redis | **6+** (7 recommended) | `redis`, `redis-namespace`, Sidekiq |
| ImageMagick / libvips | latest | `image_processing` gem (Active Storage variants) |
| Overmind (or Foreman) | latest | `Procfile.dev`, `pnpm dev` |

> PostgreSQL must have the `vector` (pgvector) extension available — it is used by
> Captain AI / article embeddings. On macOS: `brew install pgvector`.

---

## 2. One-time prerequisites (macOS)

```bash
# Ruby via rbenv (recommended — see CLAUDE.md)
brew install rbenv ruby-build
rbenv install 3.4.4
rbenv local 3.4.4
eval "$(rbenv init -)"   # add to ~/.zshrc

# Node 24 + pnpm 10
brew install node@24
corepack enable
corepack prepare pnpm@10.2.0 --activate

# Services
brew install postgresql@16 redis pgvector imagemagick libvips overmind
brew services start postgresql@16
brew services start redis
```

---

## 3. Setup commands (run in order)

```bash
# 1. Clone & enter
cd inbox

# 2. Init rbenv so the right Ruby/Bundler is used (per CLAUDE.md)
eval "$(rbenv init -)"

# 3. Install dependencies
bundle install        # Ruby gems
pnpm install          # JS packages

# 4. Environment file
cp .env.example .env
#   then edit .env (see section 4)

# 5. Database create + schema load + seed
bundle exec rails db:create
bundle exec rails db:chatwoot_prepare   # loads schema + enables required extensions
# (db:chatwoot_prepare is what Procfile uses on release; it is schema-safe)

# 6. Seed minimal local data (creates a demo account + login)
bundle exec rails db:seed
```

After `db:seed`, the console prints a demo admin login (typically
`john@acme.inc` / `Password1!.` — confirm in the seed output).

### Richer sample data (optional)
```bash
bundle exec rails runner "Internal::SeedAccountJob.perform_now(Account.find(<id>))"
```

---

## 4. Minimum `.env` values for local dev

Most of `.env.example` can stay blank for local work. The ones that matter:

```dotenv
SECRET_KEY_BASE=<run: bundle exec rake secret>
FRONTEND_URL=http://localhost:3000
RAILS_ENV=development

# Postgres — point at your local instance (override the docker defaults)
POSTGRES_HOST=localhost
POSTGRES_USERNAME=postgres
POSTGRES_PASSWORD=

# Redis — local instance (override the docker default)
REDIS_URL=redis://localhost:6379

# See emails locally instead of sending them
LETTER_OPENER=true

# Only needed for MFA/2FA flows:
# ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY / DETERMINISTIC_KEY / KEY_DERIVATION_SALT
#   generate with: bundle exec rails db:encryption:init
```

> `.env.example` defaults `POSTGRES_HOST=postgres` and `REDIS_URL=redis://redis:6379`
> which are **docker-compose** hostnames. For native local dev, change them to
> `localhost` as shown above.

---

## 5. Running the app

```bash
pnpm dev          # uses overmind with Procfile.dev (recommended)
# or
pnpm start:dev    # uses foreman with Procfile.dev
```

`Procfile.dev` starts three processes:

| Process | Command | Purpose |
|---------|---------|---------|
| `backend` | `bin/rails s -p 3000` | Rails/Puma web server |
| `worker` | `dotenv bundle exec sidekiq -C config/sidekiq.yml` | Background jobs |
| `vite` | `bin/vite dev` | Frontend dev server / HMR |

App is then available at **http://localhost:3000**.

Other useful endpoints:
- `/super_admin` — super admin console (devise `super_admins`)
- `/monitoring/sidekiq` — Sidekiq web UI (requires super admin login)
- `/swagger` — API docs

---

## 6. Running tests

```bash
# Ruby (RSpec)
eval "$(rbenv init -)"
bundle exec rspec                              # full suite
bundle exec rspec spec/path/to/file_spec.rb    # single file
bundle exec rspec spec/path/to/file_spec.rb:42 # single example by line

# JS/Vue (Vitest)
pnpm test           # one-shot
pnpm test:watch     # watch mode

# Linters
bundle exec rubocop -a       # Ruby autofix
pnpm eslint                  # JS/Vue
pnpm eslint:fix              # JS/Vue autofix
```

> Per project rules, **do not add specs unless explicitly asked**, but always run
> the relevant suite/linters before considering a change done.

---

## 7. Common errors & fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `PG::ConnectionBad` / `could not connect` | `.env` still points to docker hostnames | Set `POSTGRES_HOST=localhost`, `REDIS_URL=redis://localhost:6379` |
| `PG::UndefinedFile: could not open extension control file "vector"` | pgvector not installed | `brew install pgvector`, then `db:chatwoot_prepare` again |
| `Your Ruby version is ... but your Gemfile specified 3.4.4` | rbenv not initialized in shell | `eval "$(rbenv init -)"` (add to `~/.zshrc`) |
| `bundler: command not found: sidekiq` / wrong gem versions | wrong Ruby active | re-run `rbenv local 3.4.4` + `bundle install` |
| Vite assets 404 / blank dashboard | vite process not running | ensure `pnpm dev` started all 3 procs; restart |
| `Redis::CannotConnectError` | redis not running | `brew services start redis` |
| Emails not sending in dev | expected | set `LETTER_OPENER=true`; emails open in browser |
| Sidekiq web UI 403 | not logged in as super admin | create one: `bundle exec rails runner "SuperAdmin.create!(email: 'a@b.com', password: 'Password1!.')"` |
| MFA-related decryption errors | AR encryption keys unset | `bundle exec rails db:encryption:init`, copy keys into `.env` |
| Overmind "command not found" | overmind not installed | `brew install overmind` or use `pnpm start:dev` (foreman) |

---

## 8. Notes specific to this fork

- **Never** modify `db/schema.rb` or existing migration files directly.
- **Never** touch the `enterprise/` directory.
- HOF-specific code lives under the `HOF::` namespace.
- HOF changes are committed on the `hof-main` branch only (current branch is `develop`).
