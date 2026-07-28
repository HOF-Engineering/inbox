# CLAUDE CODE PROMPT — Agent conversation isolation (hard lock) + 2 UX features

You are working in our self-hosted Chatwoot fork (Rails 7 + Vue 3), deployed on Railway
(web = Puma, worker = Sidekiq, both run this repo). This is a LIVE production system with
500+ clients and 6+ agents. Work carefully, show the full diff before committing, and DO NOT push.

Repo conventions are in `CLAUDE.md` — follow them (Tailwind only, Composition API + `<script setup>`,
i18n via `en.json`, no new specs unless asked — EXCEPT where this prompt explicitly asks for specs,
`prepend_mod_with` / enterprise-overlay awareness, conventional commits).

---

# CONTEXT — the current (broken) behaviour

We need **strict per-agent conversation isolation**: an agent must ONLY ever be able to read
conversations **assigned to them**. Today that is NOT the case. Verified current state:

- `app/services/conversations/permission_filter_service.rb` → for a non-admin it returns
  `conversations.where(inbox: user.inboxes...)` — i.e. **every conversation in every inbox the agent
  is a member of**, regardless of assignee.
- `assignee_type` (`me` / `unassigned` / `all`) in `app/finders/conversation_finder.rb#filter_by_assignee_type`
  is a **cosmetic UI filter, not a security boundary**. Passing `assignee_type=all` (or omitting it)
  returns everything the agent's inbox membership allows.
- The frontend hides the Unassigned/All tabs for agents (`app/javascript/dashboard/components/ChatList.vue`
  filters `assigneeTabItems` with `!isAgent.value || key === 'me'`), so this is **UI-only hiding** —
  the mobile app or any direct API call still gets everything.
- `app/policies/conversation_policy.rb#show?` grants access on `inbox_access? || team_access?` —
  no assignee check at all. `show?` is also the ONLY gate for mutating single-conversation actions.
- `app/services/search_service.rb` does **not** use `PermissionFilterService` at all (inbox-membership
  only), and `should_skip_inbox_filtering?` drops inbox filtering entirely when the agent is a member
  of all inboxes.
- `app/listeners/action_cable_listener.rb#user_tokens` broadcasts realtime events — **including message
  content** (`Message#push_event_data`) — to `conversation.inbox.members` + all admins. So an agent
  receives live messages for conversations that are not theirs, over the websocket.
- `enterprise/app/services/captain/tools/copilot/get_conversation_service.rb` and
  `enterprise/app/services/captain/copilot/chat_service.rb` look conversations up **account-wide**
  with no inbox/assignee check.

**Decisions already made (do not re-litigate):**
1. Agents see **ONLY conversations assigned to them**. No unassigned access, no "all" access.
   Unassigned conversations are handled by **administrators only** (they assign them out).
2. **Team-based access must be removed** from the agent path (it currently allows seeing
   non-assigned conversations — a loophole).
3. Administrators keep full visibility (unchanged).
4. Enforcement must be **server-side at shared choke points**, so web, mobile app and raw API
   all inherit it. No frontend-only fixes.

---

# PHASE 1 — Hard lock agent visibility to assigned-only (highest priority)

## 1.1 Single source of truth

Add ONE canonical scope and make every read path use it. Add to `app/models/conversation.rb`:

```ruby
scope :visible_to_agent, ->(user) { where(assignee_id: user.id) }
```

Do **not** add a `default_scope` (the codebase deliberately has none for tenancy; a default_scope
would break admin paths, reports and jobs).

## 1.2 `app/services/conversations/permission_filter_service.rb` — the main choke point

This service is already used by: `ConversationFinder` (index / meta / search / filter),
`app/controllers/api/v1/accounts/contacts/conversations_controller.rb`,
`app/controllers/api/v1/accounts/contacts/attachments_controller.rb`,
`enterprise/app/controllers/api/v1/accounts/companies/conversations_controller.rb`,
`app/services/conversations/unread_counts/builder.rb`, `app/jobs/bulk_actions_job.rb`, and
`enterprise/app/services/captain/tools/copilot/search_conversations_service.rb`.
Fixing it fixes all of them.

- Keep `perform` returning everything for `administrator`.
- For every non-administrator, return `accessible_conversations.visible_to_agent(user)`
  (inbox membership AND assignee = user).
- Add a private `restrict_to_assigned(scope)` helper so the enterprise overlay can reuse it.

## 1.3 Enterprise overlay must not widen it

`enterprise/app/services/enterprise/conversations/permission_filter_service.rb` prepends this service
and, for custom roles, returns broader sets (`conversation_manage` → all in inbox;
`conversation_unassigned_manage` → unassigned + mine). Wrap its result so it can **never** be wider
than assigned-only: pass the final relation through `restrict_to_assigned` before returning.
Same for `enterprise/app/finders/enterprise/conversation_finder.rb`
(`participating_visible_conversations` re-derives from `current_account.conversations` — it must also
be restricted to `assignee_id = current_user.id`).

## 1.4 `app/policies/conversation_policy.rb` — single-record gate

- `show?` → `administrator? || agent_bot? || (inbox_access? && assigned_to_user?)`.
- Remove `team_access?` from the agent path (delete the method or leave it unused — but it must not
  grant access).
- Keep `destroy?` admin-only.
- Check `enterprise/app/policies/enterprise/conversation_policy.rb`: it calls `super` first, so it
  inherits the stricter rule — verify it cannot return `true` for a non-assigned conversation
  (the `conversation_manage` branch currently would; make it AND with `assigned_to_user?`).

## 1.5 Close the paths that bypass the choke point

1. **`app/services/search_service.rb`** — add assignee restriction for non-admins on BOTH
   `filter_conversations` and every message-search path (`filter_messages_with_like`,
   `filter_messages_with_gin`, `advanced_search`), by joining/filtering on
   `conversations.assignee_id = current_user.id`. Also make `should_skip_inbox_filtering?` never skip
   filtering for non-admins.
2. **`app/listeners/action_cable_listener.rb`** — this is the websocket leak (affects the mobile app
   directly). Add a helper e.g. `conversation_audience_tokens(account, conversation)` that returns
   **only** the assignee's `pubsub_token` (if any) + `account.administrators` tokens, and use it for
   the conversation-scoped events instead of `user_tokens(account, conversation.inbox.members)`:
   `message_created`, `message_updated`, `conversation_created`, `conversation_updated`,
   `conversation_status_changed`, `conversation_contact_changed`, `conversation_typing_on/off`
   (`typing_event_listener_tokens`), `conversation_mentioned` (keep mention semantics — mentioned user
   only), `assignee_changed`, `team_changed`.
   For `assignee_changed`, ALSO include the previous assignee's token when available (so the
   conversation disappears from their list in realtime) — use the model's dirty/previous-changes data
   if accessible, otherwise document the limitation in a comment.
3. **`enterprise/app/services/captain/tools/copilot/get_conversation_service.rb`** — currently
   `Conversation.find_by(display_id:, account_id:)` then `to_llm_text(include_private_messages: true)`.
   Scope the lookup through `Conversations::PermissionFilterService` (or the policy) so an agent can
   only fetch their own conversation.
4. **`enterprise/app/services/captain/copilot/chat_service.rb`** — same: resolve `conversation_id`
   through the permission filter, not `@account.conversations`.
5. **`app/finders/message_finder.rb`** — leave the logic, but add a comment documenting that it
   performs no authorization and relies on an already-authorized `@conversation`.
6. **`app/controllers/api/v1/accounts/bulk_actions_controller.rb`** — the Conversation branch has no
   `authorize` call; safety currently depends only on the job. Add an explicit authorize/scope check.
7. Audit and report (do not necessarily change): `app/finders/notification_finder.rb`,
   `app/controllers/api/v1/accounts/csat_survey_responses_controller.rb`, reports controllers
   (`app/controllers/api/v2/accounts/reports_controller.rb`) — confirm they are admin-gated.

## 1.6 Dead code / hardening

- `app/finders/conversation_finder.rb`: `@is_admin` (set in `initialize`) is never read — remove it.
- `find_conversation_by_inbox` starts from `current_account.conversations` and relies entirely on the
  permission filter. Add a comment marking that line as security-critical.

## 1.7 Specs — REQUIRED for this phase (this is the actual guarantee)

Create `spec/requests/agent_conversation_isolation_spec.rb` (and enterprise equivalent under
`spec/enterprise/` if needed). Set up: one account, one inbox, `agent_a` and `agent_b` BOTH members
of that inbox, conversation `conv_a` assigned to `agent_a`, `conv_b` assigned to `agent_b`, and
`conv_unassigned` with no assignee. Then assert **as `agent_a`** that `conv_b` and `conv_unassigned`
are NEVER visible/readable through ANY of these:

- `GET /api/v1/accounts/:id/conversations` with `assignee_type` = `all`, `unassigned`, `assigned`, and omitted
- `GET /api/v1/accounts/:id/conversations/meta` (counts must not include others')
- `POST /api/v1/accounts/:id/conversations/filter` with a payload targeting `assignee_id` / `status` / `inbox_id`
- `GET /api/v1/accounts/:id/conversations/search?q=...`
- `GET /api/v1/accounts/:id/conversations/:display_id` (expect 404/401, not 200)
- `GET /api/v1/accounts/:id/conversations/:display_id/messages`
- `GET /api/v1/accounts/:id/conversations/:display_id/attachments`
- `GET /api/v1/accounts/:id/contacts/:contact_id/conversations`
- `GET /api/v1/accounts/:id/contacts/:contact_id/attachments`
- `GET /api/v1/conversations/unread_counts`
- `POST /api/v1/accounts/:id/bulk_actions` targeting `conv_b`
- mutating actions on `conv_b`: `toggle_status`, `toggle_priority`, `assignments`, `labels`,
  `custom_attributes`, `transcript`, `update_last_seen`, `unread` — all must be denied
- `GET /api/v1/accounts/:id/search?q=...` (global search: conversations AND messages)

Also add a spec asserting an administrator still sees everything (no regression), and a spec for
`ActionCableListener` asserting `agent_b`'s `pubsub_token` is NOT in the broadcast audience for a
message created on `conv_a`.

Run: `bundle exec rspec spec/requests/agent_conversation_isolation_spec.rb` and make it green.

## 1.8 Operational note to report back to me

Because agents will no longer see unassigned conversations, new inbound leads become invisible to
agents until an admin assigns them. In your summary, tell me:
- whether inbox **auto-assignment** (round-robin) is available/enabled on our inboxes and where to
  toggle it, and
- which agent-facing UI elements now become dead (e.g. Unassigned/All tabs, folders/saved filters
  that reference other assignees) and should be hidden for the `agent` role.

---

# PHASE 2 — WhatsApp template picker: grouping + category badge

File: `app/javascript/dashboard/components/widgets/conversation/WhatsappTemplates/TemplatesPicker.vue`
(templates come from the getter `inboxes/getFilteredWhatsAppTemplates` in
`app/javascript/dashboard/store/modules/inboxes.js`; each template has
`id, name, language, category, status, components[]`). Today the picker only has a free-text search on
`template.name`, renders templates in raw array order, with no grouping.

We have many templates now and agents struggle to find the right one.

1. **Group templates into functional groups**, derived from the template NAME (case-insensitive
   keyword match), rendered as filter chips/tabs: `All`, `Greetings`, `Follow-ups`, `Quotes & Details`,
   `Other`. Suggested keyword map (put it in a small exported constant so we can extend it):
   - Greetings: `greeting`, `welcome`, `intro`, `checkin`, `check_in`
   - Follow-ups: `followup`, `follow_up`, `reminder`, `missed`, `no_answer`, `reengage`
   - Quotes & Details: `quote`, `detail`, `artwork`, `sample`, `doc`, `payment`, `call`
   - anything unmatched → `Other`
   Keep the existing name search working **in combination with** the active group.
2. **Show a prominent category badge** on each template row: `UTILITY` (green) vs `MARKETING`
   (amber/orange), using Tailwind classes only. This matters operationally — agents should prefer
   Utility templates. Keep the existing category text block or replace it with the badge, your call,
   but the distinction must be obvious at a glance.
3. Add all new strings to `app/javascript/dashboard/i18n/locale/en/whatsappTemplates.json` under
   `WHATSAPP_TEMPLATES.PICKER.*` (e.g. `GROUPS.ALL`, `GROUPS.GREETINGS`, …). English only — other
   locales are community-managed.
4. Do not change the template object shape or the store getter (it's also consumed by
   `components-next/NewConversation/components/WhatsAppOptions.vue` and
   `components-next/Campaigns/.../WhatsAppCampaignForm.vue`). Grouping must be presentational.
5. Known pre-existing bug you may fix while here: `COMPONENT_TYPES` in
   `app/javascript/dashboard/helper/templateHelper.js` is missing `FOOTER`, so the FOOTER block in the
   picker never renders.

---

# PHASE 3 — "Unread" tab in the conversation list

Today the tabs are `Mine` / `Unassigned` / `All`, defined by `ASSIGNEE_TYPE_TAB_PERMISSIONS` in
`app/javascript/dashboard/constants/permissions.js` + `ASSIGNEE_TYPE` in
`app/javascript/dashboard/constants/globals.js`, built into `assigneeTabItems` in
`app/javascript/dashboard/components/ChatList.vue`, rendered by
`app/javascript/dashboard/components/widgets/ChatTypeTabs.vue`.

Add an **`Unread` tab** alongside them:

- For an **agent**, it shows their assigned conversations with `unread_count > 0`.
  For an **administrator**, it shows unread across everything they can see.
- Implementation: add tab key `unread`. When active, keep the same server-side query the role is
  entitled to (agents: `assignee_type=me`; admins: `assignee_type=all`) and filter the resulting list
  by `unread_count > 0`, reusing the existing per-conversation `unread_count` field
  (`store/modules/conversations/index.js` mutation `UPDATE_MESSAGE_UNREAD_COUNT`,
  `ConversationCard.vue` `unreadCount`). Consider reusing the existing
  `SORT_BY_TYPE.UNREAD` sort helper (`sortByUnreadStatus` in ChatList.vue).
- The tab count must reflect the number of unread conversations in that scope.
- The tab must respect Phase 1: it must NOT introduce any query that could return another agent's
  conversations. Server-side it must go through the same permission-filtered endpoints.
- Add i18n strings under `CHAT_LIST.ASSIGNEE_TYPE_TABS.unread` in
  `app/javascript/dashboard/i18n/locale/en/chatlist.json`.
- Keep the `Alt+KeyN` tab-cycling shortcut in `ChatTypeTabs.vue` working with the extra tab.

---

# RULES

- **Phase 1 first**, and it must be complete + specs green before you touch Phase 2/3.
- Additive and surgical. Do NOT refactor unrelated code, do NOT add DB migrations, do NOT touch
  the WhatsApp sending pipeline, the lead-capture/auto-form jobs
  (`app/jobs/lead_welcome_form_job.rb`, `app/jobs/pack_welcome_form_job.rb`,
  `app/jobs/lead_sheet_forward_job.rb`,
  `app/services/whatsapp/incoming_message_whatsapp_cloud_service.rb`), R2/storage config, or
  anything under `config/` unless strictly required.
- Administrator behaviour must be **unchanged** — verify with specs.
- Respect the enterprise overlay: where OSS code is prepended by `enterprise/`, update both so the
  overlay can never widen access.
- Run `bundle exec rubocop -a` on changed Ruby files and `pnpm eslint:fix` on changed JS/Vue files.
- Show me the **full diff of every changed/new file before committing**. Do not push.

# WHEN DONE — report

1. A table of every conversation-returning path and how it is now restricted.
2. Any path you found that you could NOT lock down, and why.
3. The exact commands to run the isolation specs.
4. The operational notes requested in 1.8.
5. Confirmation that admin visibility and the WhatsApp lead-capture flows are untouched.
