# Client Cache Identity Layering (Backend Identity, Not Connection Profile)

Status: design for owner review (2026-07-28). Implementation queued behind
#TASK-2811 (avatar content-addressing) — both touch the catalog snapshot and
cache plumbing; serialize to avoid same-file conflicts.
Companion test cases: written at dispatch time, after owner sign-off.

## Owner requirement (verbatim intent)

The owner frequently switches gateways, and often the "switch" is **the same
gateway reached through a different network entry** (different domain, LAN
IP, VPN address). Caches must key on **the data's own identity**, never the
connection profile: list *views* may re-fetch after a switch, but anything
atomic with a globally unique identity (threads, avatars, …) comes from a
global cache regardless of which URL delivered it.

## Root cause (surveyed 2026-07-28, full inventory in task thread)

- `currentGatewayScopeId = fnv1a64(lowercased full URL string)`
  (`GaryxMobileModel+Gateway.swift:109-113`,
  `GaryxMobileGatewaySettingsModels.swift:124-131`). A domain/port/IP change
  is a brand-new scope; every scoped cache misses.
- Even `.suspend` (the "coming back later" path) wipes nearly everything:
  transcript disk cache `clearAll()` (key is threadId-only, so the code
  can't tell whose thread is whose), widget stores cleared unconditionally,
  all in-memory summaries/feeds reset. Only composer drafts survive.
- The server already publishes a persistent backend identity:
  `store_incarnation_id` — a UUID stored in SQLite (`garyx_db/
  store_incarnation.rs:10-51`), stable across restarts and domains, rotated
  only by explicit whole-data-dir restore. iOS decodes it on every
  recent-threads / summaries / favorites page and uses it as an in-memory
  consistency fence (`GaryxRecentThreadFeeds.swift:474-498` force-replaces
  the list when it changes) — but never persists it and never keys any cache
  with it. `server_boot_id` (per-process UUID) likewise.
- Assorted drift: favorites keys its scope by the raw normalized URL while
  everything else uses the hash (`GaryxMobileModel+Gateway.swift:132-136`);
  capsule thumbnails are already global-by-id (correct, but by accident and
  undocumented); one test writes the recent-filter key scoped while
  production reads it unscoped.

## Identity model — four cache layers

**L0 · Content-addressed (global, no gateway dimension).**
Key = content hash. Avatar blobs (#TASK-2811, already amended), and —
formalized here — capsule thumbnails keyed `id.rN.rendition.schema`
(capsule ids are UUIDs; the existing keying is correct, keep it and document
it as L0 rather than "accidental").

**L1 · Globally unique entities (global pool, keyed by entity id).**
`thread::<uuid>` is generated as a UUID by the gateway; it cannot collide
across backends. Members:
- Transcript disk cache: already keyed by threadId only
  (`GaryxTranscriptCache.swift:214-280`). Change: **stop clearing it on
  gateway/profile switch** (`GaryxMobileModel+Gateway.swift:240-245` — the
  clearAll and its "not unique across gateways" rationale are removed; the
  implementer must verify and cite the router's thread-id generation as
  UUID in the change). TTL and size bounds stay; the existing
  `gatewayRequestToken` response-ownership gate stays (it guards in-flight
  attribution, not storage identity).
- Thread summary cache (`GaryxThreadSummaryCache`): stays in-memory but is
  no longer reset on scope exit; entries are keyed by threadId and are
  valid regardless of the delivering URL. Capacity/pin-lease semantics
  unchanged.
Safety: backend B never references backend A's thread ids (UUID), so a
global pool cannot cross-serve; stale-content risk is unchanged from today
(entries refresh through the normal per-thread fetch paths).

**L2 · Backend-namespaced state (keyed by backend identity, not URL).**
Backend identity = `store_incarnation_id`. Members (today all keyed by
URL-hash scope): catalog cache snapshot, last-opened-thread,
last-session-on-thread, new-thread workspace selection/mode, pinned-order
outbox, composer draft partitions (`GaryxGatewayScope.identity`), scope
epochs, push-registration target. Agent ids, workspace paths, favorites are
namespaced per backend — `gary` on backend A is not `gary` on backend B —
so these must not be global, but they must survive a domain change for the
same backend.

**L3 · Views (in-memory, refetch on switch).**
Feed order, cursors, pager state, search state — exactly today's behavior:
re-pulled on switch/reconnect, but their rows hydrate instantly from L1.

## The bootstrap gap and its resolution

Backend identity is only known **after** first contact. Resolution:

- **Persistent endpoint→identity map** (`url-hash → last-seen
  store_incarnation_id`, plus reverse index), updated on every confirmed
  contact.
- On profile activation, resolve optimistically through the map: load the
  mapped identity's L2 partition immediately (instant warm start for a
  known endpoint). An unmapped endpoint starts with an empty L2 partition.
- **Gateway change (small server addition): `/api/status` gains
  `store_incarnation_id` and `server_boot_id`** so the very first probe of
  `connectAndRefresh` confirms identity before any list lands. (Today the
  probe response carries neither; identity would otherwise arrive only with
  the first page.)
- On confirmation: if the confirmed identity differs from the optimistic
  one (the URL now points at a different backend), atomically switch to the
  confirmed identity's partition and force-replace visible lists — this
  reuses the exact `identityReplacement` machinery the feeds already have
  for mid-session incarnation changes. Update the map.
- `server_boot_id` keeps its current role (process-restart fence), never a
  cache key.

## Semantics rewritten on the new key

- **Switch/suspend**: leaving a backend suspends its L2 partition intact
  (composer drafts, catalog snapshot, last-opened thread, pinned outbox);
  L1/L0 are untouched by definition; L3 resets. Returning to the same
  backend — through **any** URL — restores L2 and hydrates L3 from L1.
- **Revoke** (same endpoint, credentials changed): unchanged trust
  semantics, now applied to the identity partition reached through that
  endpoint (epoch bump + composer settlement exactly as today).
- **Widget**: snapshot becomes identity-tagged instead of
  cleared-on-switch; a switch shows the previous backend's rows only until
  the new backend's first commit replaces them (no more blank widget after
  every switch). Avatar references in widget rows are already global (L0).
- **Migration**: one-shot, on first activation per endpoint after update —
  when identity is confirmed for a URL-hash scope, migrate that scope's
  UserDefaults keys, composer SQLite partition rows, and scope-epoch entry
  to the identity key; leave a tombstone so re-runs are no-ops. Orphan
  URL-hash partitions (endpoints never contacted again) are bounded and
  inert; no background sweeper.
- **Scope-string consolidation**: favorites' raw-URL scope and the
  URL-hash scope collapse into the single backend-identity key; the
  test/production mismatch on the recent-filter key gets fixed to the
  production (global) semantics.

## Non-goals

- Gateway profile UX (one-logical-gateway → N endpoints grouping in the
  switcher, the 8-profile cap): connection-management UX, not caching;
  recorded as possible follow-up, out of scope here.
- Keychain layout (token per endpoint profile) is correct as-is — tokens
  belong to endpoints, not backends.
- Desktop: same layering applies in principle, but desktop today keeps far
  less offline state; a follow-up audit decides what (if anything) to move.
  This design's implementation scope is iOS + the `/api/status` field.
- No change to server-side data contracts beyond the status fields; no
  change to `render_state` or transcript wire formats.

## Impact

| Scenario (today → after) |
|---|
| Same gateway, second domain: everything cold — catalog re-pull 748 KB→(28 KB post-#2811), transcripts gone, widget blank → **warm start: L2 restored via identity map, transcripts/summaries hit L1, only L3 views re-pull** |
| Switch A→B→A (distinct backends): A's transcripts wiped on leaving → A's L1/L2 intact; return is instant, lists refresh in background |
| URL reused for a different backend: undefined-ish today (scope collides) → detected on first probe via status identity; partition switch + forced list replacement |
| Cross-backend leakage: prevented by wiping everything → prevented by identity — UUIDs cannot collide, L2 is partitioned, L0 is content-addressed |

Touched: iOS (scope plumbing, transcript/summary lifecycle, widget store,
composer partition migration, endpoint→identity map) + gateway
(`/api/status` two fields) + docs. Serialized after #TASK-2811.
