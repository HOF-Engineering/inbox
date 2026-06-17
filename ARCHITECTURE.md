# ARCHITECTURE.md — Chatwoot (HOF Immigration fork)

How this application is wired together. Grounded in `config/routes.rb`, the core
models (`conversation.rb`, `message.rb`, `user.rb`, `account.rb`), `app/listeners/`,
`app/jobs/`, `app/services/`, and `app/javascript/`.

> Chatwoot is a Rails 7.1 monolith (Ruby 3.4.4) with a Vue 3 SPA frontend served
> via Vite, Sidekiq for background work, and ActionCable for realtime. It is
> multi-tenant: almost everything is scoped to an `Account`.

---

## 1. High-level component map

```
Browser (Vue 3 SPA)  ──HTTP/JSON──▶  Rails API (api/v1, account-scoped)
        │                                   │
        │◀──── WebSocket (ActionCable) ─────┤  controllers → services
        │                                   │       │
   Vite dev server                          │       ▼
                                            │   ActiveRecord ──▶ PostgreSQL (+ pgvector)
                                            │       │
                                            │       ▼ (model callbacks)
                                            │   Wisper dispatcher ──▶ Listeners
                                            │                            │
External channels (WhatsApp/FB/...)         │                            ▼
   ──webhooks──▶ Rails webhook controllers  └──────────────────▶  Sidekiq jobs ──▶ Redis
                                                                     (emails, replies,
                                                                      webhooks, CRM sync)
```

---

## 2. Request flow (browser → Rails → DB)

1. The SPA boots from `app/javascript/entrypoints/dashboard.js` (mounted by the
   `dashboard#index` Rails view; see `root to: 'dashboard#index'` in `routes.rb`).
2. The Vue app makes JSON calls to **account-scoped** API routes under
   `/api/v1/accounts/:account_id/...` (see the big `resources :accounts` block in
   `config/routes.rb`).
3. Authentication is **`devise_token_auth`** (token in headers), mounted at `/auth`.
   Authorization is **Pundit** policies (`app/policies`).
4. A controller (e.g. `Api::V1::Accounts::ConversationsController`) loads the
   account/records, applies a **policy**, then delegates business logic to a
   **service** (`app/services/...`) or **finder** (`app/finders/...`).
5. ActiveRecord reads/writes **PostgreSQL**. `Current` (an `ActiveSupport::CurrentAttributes`
   object) carries `Current.account`, `Current.user`, `Current.executed_by` through the request.
6. Model **callbacks** (`after_create_commit`, `after_update_commit`) fire domain
   events through the Wisper dispatcher (section 5), which is how side effects
   (realtime push, notifications, webhooks, automation) happen without bloating controllers.

API versions present: `api/v1` (main, account-scoped), `api/v2` (reports/analytics),
`platform/api/v1` (instance/platform admin), `public/api/v1` (contact-facing widget/portal).

---

## 3. Real-time messaging (ActionCable / WebSockets)

- **Server**: ActionCable channels in `app/channels/` broadcast over Redis.
- **Client**: `@rails/actioncable` (`package.json`) connects from the SPA; the
  `pubsub_token` on `User` (see `Pubsubable` concern in `user.rb`) authorizes the socket.
- **How messages reach the browser**:
  1. A `Message` is created → `after_create_commit` → `execute_after_create_commit_callbacks`
     in `app/models/message.rb` → `dispatch_create_events` dispatches `MESSAGE_CREATED`.
  2. `ActionCableListener` (`app/listeners/action_cable_listener.rb`) handles the event
     and pushes `push_event_data` to the relevant subscribers (assignee, inbox, account
     admins, the contact widget).
  3. The SPA receives the socket event and updates its Vuex/Pinia store, re-rendering
     the conversation.
- Typing indicators, presence/availability, conversation updates, and unread counts
  all flow through the same dispatch → `ActionCableListener` → WebSocket path.

---

## 4. Background jobs (Sidekiq)

- **Engine**: `sidekiq` (7.3) backed by Redis; config in `config/sidekiq.yml`.
  Queues, in priority order: `critical, high, medium, default, mailers,
  action_mailbox_routing, low, scheduled_jobs, deferred, purgable, housekeeping, ...`.
- **Jobs** live in `app/jobs/` (e.g. `send_reply_job.rb`, `webhook_job.rb`,
  `hook_job.rb`, `event_dispatcher_job.rb`, `conversation_reply_email_job.rb`).
- **Event → job bridge**: `EventDispatcherJob` and the listeners push work onto
  Sidekiq so request threads stay fast. Example: a new outgoing `Message` schedules
  `SendReplyJob` (`message.rb#send_reply`) which actually delivers to the channel.
- **Scheduled / cron jobs**: `sidekiq-cron` reads `config/schedule.yml`. Key entries:
  - `TriggerScheduledItemsJob` — every 5 min (campaigns, snooze reopen, auto-resolve,
    WhatsApp template sync).
  - `Internal::TriggerHourlyScheduledItemsJob` — hourly.
  - `Internal::TriggerDailyScheduledItemsJob` — daily.
  - plus IMAP fetch (1 min), account deletion, stale cleanup, periodic assignment.
  > This is the natural home for an HOF SLA-alert cron job (see HOF doc / Step 4).

---

## 5. Domain events (Wisper pub/sub) — the backbone

This is the most important pattern to understand. Models do **not** call services
directly for cross-cutting concerns; they dispatch events.

- Models dispatch via `Rails.configuration.dispatcher.dispatch(EVENT_NAME, ...)`
  (see `conversation.rb#dispatcher_dispatch`, `message.rb#dispatch_create_events`).
- The dispatcher fans events out to **listeners** in `app/listeners/`:
  - `ActionCableListener` → realtime WebSocket push
  - `NotificationListener` → in-app + email/push notifications
  - `WebhookListener` / `HookListener` → outbound webhooks & integrations
  - `AutomationRuleListener` → automation rules engine
  - `CsatSurveyListener`, `ReportingEventListener`, `CampaignListener`, etc.
- Example for HOF-relevant work: when a conversation is resolved, `Conversation`
  dispatches `CONVERSATION_RESOLVED`; `HookListener#conversation_resolved` then runs
  the account's integration hooks (this is exactly where CRM sync hangs off — see Step 4).

---

## 6. WhatsApp integration

WhatsApp is one of several **channels** (`Channel::Whatsapp`, declared in `account.rb`
as `has_many :whatsapp_channels`). For HOF this is the primary channel.

**Inbound (customer → Chatwoot):**
1. Provider (Meta WhatsApp Cloud API or 360dialog) POSTs to
   `POST /webhooks/whatsapp/:phone_number` (`config/routes.rb` →
   `webhooks/whatsapp#process_payload`). `GET` variant verifies the webhook.
2. The webhook controller hands off to services in `app/services/whatsapp/`:
   - `IncomingMessageService` / `IncomingMessageWhatsappCloudService` parse the payload,
   - resolve/create the `Contact` + `ContactInbox`, find/create the `Conversation`,
   - create the inbound `Message` (which then triggers the normal event flow in section 5).
   - dedup is handled via `message_dedup_lock.rb`.

**Outbound (agent → customer):**
1. Agent reply creates an outgoing `Message` → `SendReplyJob` → channel send path →
   `app/services/whatsapp/send_on_whatsapp_service.rb` calls the provider API.
2. Provider abstractions live in `app/services/whatsapp/providers/`.
3. **Template messages** (required outside the 24h session window): handled by
   `template_processor_service.rb`, `populate_template_parameters_service.rb`,
   and synced periodically by `Channels::Whatsapp::TemplatesSyncSchedulerJob`.

**Delivery status** updates come back via webhook and update `Message#status`
(`sent/delivered/read/failed`).

---

## 7. Multi-tenancy (accounts)

- **`Account`** is the tenant boundary (`app/models/account.rb`). Nearly every model
  belongs to an account: `conversations`, `messages`, `contacts`, `inboxes`, `users`
  (via `account_users`), `webhooks`, `hooks`, etc.
- **Users ↔ Accounts is many-to-many** through `account_users` (a user can belong to
  multiple accounts; `AccountUser` carries the `role`: `agent` / `administrator`).
- **Routing** enforces tenancy: the main API is nested under
  `/api/v1/accounts/:account_id/...`. Controllers scope every query to that account,
  and `Current.account` is set per request.
- **Per-account config** is stored in JSONB columns on `Account`: `settings`,
  `custom_attributes`, `internal_attributes`, `limits`, plus `feature_flags`
  (a bit-flag integer via `FlagShihTzu` / `Featurable`).
- **Per-account sequences**: `display_id` for conversations is generated by a DB trigger
  per account (`conv_dpid_seq_<account_id>`, see triggers in `conversation.rb`/`account.rb`).
- **Enterprise overlay**: `enterprise/` extends OSS via `prepend_mod_with` /
  `include_mod_with` (see the bottom of each core model). Do not edit `enterprise/`.

---

## 8. Frontend architecture (Vue.js)

Located in `app/javascript/`. Multiple independent apps, each with its own entrypoint
in `app/javascript/entrypoints/`:

| App | Folder | Purpose |
|-----|--------|---------|
| Agent dashboard | `dashboard/` | Main agent SPA (the big one) |
| Live-chat widget | `widget/` + `sdk/` | Embeddable customer chat |
| Help center | `portal/` + `v3/` | Public knowledge base |
| Survey | `survey/` | CSAT survey pages |
| Super admin | `superadmin_pages/` | Internal admin UI |
| Design system | `design-system/` + `shared/` | Shared components/composables |

**Dashboard internals (`app/javascript/dashboard/`):**
- `App.vue` — root component.
- `routes/` — `vue-router` route definitions (mirror the account-scoped URL structure).
- `store/` — **legacy Vuex** store (being phased out).
- `stores/` — **Pinia** stores (the new pattern; `pinia` is in `package.json`).
- `api/` — axios-based API clients that call the Rails `api/v1` endpoints.
- `components/` — legacy components; **`components-next/`** — the current/preferred
  components (per CLAUDE.md, use `components-next/` for message bubbles).
- `composables/` — Composition API hooks; `i18n/` — translations (frontend → `en.json`).
- `helper/`, `mixins/`, `modules/`, `services/` — supporting utilities.

**Conventions** (from CLAUDE.md): Vue 3 Composition API with `<script setup>`,
PascalCase components, camelCase events, PropTypes, **Tailwind only** (no custom/scoped
CSS, colors from `tailwind.config.js`), and no bare strings (use i18n).

**Realtime on the client**: `@rails/actioncable` subscribes using the user's
`pubsub_token`; incoming socket events mutate the store, which reactively updates the UI.

---

## 9. Where things live (quick reference)

| Concern | Location |
|--------|----------|
| Routes | `config/routes.rb` |
| Models | `app/models/` (core: conversation, message, user, account) |
| Controllers | `app/controllers/api/v1/...` (account-scoped) |
| Business logic | `app/services/` |
| Query objects | `app/finders/` |
| Domain events | dispatched in models → `app/listeners/` |
| Background jobs | `app/jobs/`; cron in `config/schedule.yml` |
| Mailers | `app/mailers/` (admin alerts: `app/mailers/administrator_notifications/`) |
| Channels (realtime) | `app/channels/` |
| Integrations / CRM | `app/services/crm/`, `app/listeners/hook_listener.rb`, `app/jobs/crm/` |
| Frontend | `app/javascript/` |
| Enterprise overlay | `enterprise/` (do not edit) |
