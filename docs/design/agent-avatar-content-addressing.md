# Content-Addressed Agent Avatars

Status: approved for implementation (owner decision 2026-07-28: "只有出现不认识
的头像才拉取一次，否则一直用缓存；拉取也是异步")
Companion test cases: `docs/design/agent-avatar-content-addressing-test-cases.md`
Origin: Debt 1 of `docs/design/mobile-home-payload-review-debt.md`

## Problem (measured)

`/api/custom-agents` is 748 KB; 97.8% (720 KB) is `avatar_data_url` base64.
Six custom avatars are 85–108 KB uncompressed PNGs. Because the bytes are
inlined in JSON there is no HTTP caching of any kind: every catalog fetch
re-downloads every avatar, gzip recovers only ~25% on base64, the gateway
rereads/rewrites a 732 KB `custom-agents.json` on every store operation, and
iOS re-encodes the same blobs into a ~1 MB `UserDefaults` catalog snapshot on
the main actor.

Survey (2026-07-28, full call-site inventory in the task thread) established:

- Gateway stores the raw string with **zero validation and no size limit**
  (`custom_agents.rs` upsert; the only handling is trim + empty→None).
  Upsert has three-state merge semantics: `Some(non-empty)` overwrite,
  `Some(empty)` clear, `None` keep-existing — pinned by
  `upsert_preserves_and_clears_avatar_data_url`.
- Built-in agent avatars are compile-embedded PNGs re-encoded to data URLs at
  startup; they never touch the persisted store (`custom_agent.rs:69-174`,
  `agent_store.rs:130-138`, store envelope v2).
- iOS already has an identity-keyed avatar disk cache in the App Group
  container (`GaryxAvatarDiskStore`, `GaryxAvatarCache.swift`, design
  `docs/design/ios-agent-avatar-cache.md`), with fingerprint dedup and a
  widget read path (`GaryxWidgetAvatarPayloadLoader` reads
  `GaryxAvatarCache/v1/index.json` + blob files; the thread projector prefers
  `avatarScope`+`avatarFingerprint` over inline data URLs).
- Desktop renders `<img src=dataurl>` via `AgentOptionAvatar` with no disk
  cache; identity resolution goes through `thread-avatar.ts`.
- CLI strips `avatar_data_url` from JSON output and never sends the key on
  mutations (so CLI updates hit the keep-existing branch). Bot channels,
  router, and bridge do not consume avatars at all.
- Size constraints today are inconsistent per client: gateway none, iOS
  normalizer 450 KB, iOS cache 512 KB, desktop 700k chars.

## Goal model (owner's rule)

**The hash is the identity.** A catalog row carries only a content hash of
the avatar bytes. A client that has that hash on disk renders it with **zero
network traffic — not even a conditional request**. A hash the client has
never seen ("不认识的头像") triggers **one asynchronous fetch**, stored
forever (content-addressed data is immutable). A changed avatar is simply a
new hash. Rendering never blocks on fetching: unknown-hash rows show the
existing provider/initials fallback and swap in the image when it lands.

## Wire & storage contract

### Catalog row

- `CustomAgentProfile.avatar_data_url` is **removed** from the profile,
  the store envelope, and every HTTP response. Replacement:
  `avatar_hash: Option<String>` — lowercase hex sha256 of the **normalized**
  avatar bytes. `null` = no avatar.
- No dual-write, no legacy field echo (design rule: no compatibility
  shimming). Desktop, iOS, and CLI switch in the same change.
- Upsert **keeps today's request shape and three-state semantics**: clients
  still send `avatar_data_url` (a data URL is the natural upload form for a
  locally picked/generated image): `Some(non-empty)` = replace,
  `Some(empty)` = clear, `None` = keep. The server now normalizes instead of
  storing the string.

### Avatar bytes endpoint

- `GET /api/avatars/{hash}` (auth-protected, registered with the other
  protected routes). 404 for unknown hash. Response: image bytes,
  `Content-Type` sniffed from magic bytes (PNG/JPEG are the only two the
  normalizer emits), `ETag: "{hash}"`,
  `Cache-Control: public, max-age=31536000, immutable`.
- Hash-addressed responses are immutable by construction, so the endpoint
  never needs revalidation logic.

### Server-side normalization (single authority)

One `normalize_avatar(data_url) -> Result<(bytes, hash), RejectReason>`
function used by **both** the upsert path and the migration:

- Parse data URL: require `data:image/*;base64,`; reject anything else
  (including bare http(s) URLs — today they'd be stored verbatim).
- Input cap: reject decoded input > 2 MiB (aligns with the axum default body
  limit; today's three inconsistent client caps stop being load-bearing).
- Decode (PNG/JPEG/WebP in), downscale so the long edge is ≤ 256 px
  (matching the existing client normalizer targets), re-encode: PNG first;
  if the PNG exceeds 100 KiB, flatten onto `#F7F8FA` and encode JPEG q88
  (mirrors the two clients' existing fallback so visual results stay
  consistent). Output cap (post-normalize) 256 KiB — anything larger is a
  reject, not a store.
- sha256 over the normalized bytes = `avatar_hash`.
- Client-side pre-normalization (iOS `GaryxMobileAvatarImageNormalizer`,
  desktop `normalizeAvatarFile`) stays as an upload-size optimization; the
  server re-normalizes regardless. Idempotence note: normalize(normalize(x))
  must be byte-stable for the formats the normalizer itself emits, so
  re-uploading a previously normalized image yields the same hash.

### Blob store

- `<data_dir>/avatars/<hash>` — flat content-addressed files, written with
  the existing atomic-write helper, write-if-absent (same hash = same bytes,
  skip). No index file needed server-side; the file name is the index.
- **Built-in avatars unify**: at startup, ensure each compiled-in builtin
  PNG is normalized and present in the blob store (idempotent by hash);
  builtin profiles then carry `avatar_hash` like everyone else. One read
  path, no builtin special-casing in the endpoint.
- No GC. Replaced avatars leave orphan blobs of a few KiB each; a
  content-addressed store keeps them (documented trade-off — simplicity over
  a reference-counting mechanism there is no size pressure to justify).

### Store migration (v2 → v3)

- `agent_store.rs` envelope version bumps to 3. Loading a v2 document runs
  the one-shot migration inside the normal load path: for each persisted
  custom agent with `avatar_data_url`, run `normalize_avatar`, write the
  blob, replace the field with `avatar_hash`; unparseable/garbage strings
  (possible — the field was never validated) migrate to `avatar_hash: null`
  with a warning log, never a boot failure. Write back as v3 atomically.
  The version field is the migration marker; v3 documents never contain
  `avatar_data_url`.
- Expected effect on this machine: `custom-agents.json` 732 KB → ~12 KB, and
  the six oversized PNGs shrink to ≤ 100 KiB-class normalized images (most
  will land far smaller at 256 px).

## Client contract (both platforms)

The four rules, straight from the owner:

1. **Known hash ⇒ zero requests.** Disk hit renders directly; no conditional
   GET, no revalidation (immutability makes both meaningless).
2. **Unknown hash ⇒ exactly one async fetch**, deduplicated across
   concurrent requesters (an in-flight table keyed by hash); success writes
   the blob to the local store keyed by hash.
3. **Fetching never blocks rendering.** Unknown-hash rows render the
   existing fallback chain (provider artwork / initials) and refresh when
   the fetch lands. No spinners, no layout shift beyond the image swap.
4. **Failures are silent** (log-level only) and retry lazily: the next
   render that still misses the hash may trigger a new fetch attempt;
   no retry timers, no error UI. Auth stays in headers — the token never
   appears in a URL.

### iOS

- `GaryxAgentSummary.avatarDataUrl` → `avatarHash: String?` (drop the four
  legacy alias keys along with the field). `GaryxCachedAgent` follows;
  catalog snapshot version 6 → 7 (old snapshots discarded by the existing
  version gate — cold start repopulates from the connect sweep). This
  removes the ~720 KB of base64 from the UserDefaults snapshot entirely.
- Reuse the existing App Group avatar store (`GaryxAvatarDiskStore`,
  `GaryxAvatarCache/v1/`) rather than building a second cache: the stored
  record's content fingerprint becomes the server `avatar_hash` (exact
  scheme — replacing fnv1a64 with the server hash vs. mapping identity →
  server-hash — is the implementer's choice, but hash-keyed lookup must be
  O(1) and identity-independent so one image shared by N agents stores
  once). The widget channel keeps its current shape: projector passes
  scope + hash (today's `avatarFingerprint` slot), widget loads bytes from
  the shared container; the inline-data-URL fallback lane in the widget
  projection disappears with the field.
- New fetcher in Core-adjacent app layer: hash → authenticated
  `GET /api/avatars/{hash}` → validate sniffed image → write store → wake
  the row(s) that requested it. Pure decision pieces (known/unknown/in-
  flight admission) live in `GaryxMobileCore` with SwiftPM tests.
- `GaryxAgentAvatarView` keeps its API surface but resolves hash-first:
  memory cache → disk store → (fallback + async fetch). The existing
  provider-presentation fallback chain is unchanged.
- Avatar upload/generation flows keep their normalizer and keep sending
  `avatar_data_url` upstream; after a successful save they read back the
  profile's new `avatar_hash` and write the normalized bytes they already
  hold into the local store under that hash **only if the server-returned
  hash matches their local normalization** — otherwise just let the normal
  unknown-hash fetch pull the canonical bytes (server normalization is
  authoritative; do not assume client and server encoders agree).

### Desktop

- `agents.ts` wire mapping: `avatar_hash` (nullable string), contract field
  `avatarHash`. `thread-avatar.ts` identities carry the hash; option
  projections follow.
- One shared renderer-side avatar resolver: hash → in-memory object-URL
  cache → persistent cache → authenticated fetch (dedup by hash) → object
  URL. Persistent layer per desktop's existing patterns (CacheStorage in the
  renderer or a main-process disk cache — implementer's choice; the contract
  is the four client rules above). `AgentOptionAvatar` consumes the resolved
  object URL / falls back exactly as today.
- Upload/generation (`agent-avatar.ts`, `agents-hub-helpers.ts`) keep their
  pre-normalization and `avatar_data_url` upload field; read-back mirrors the
  iOS rule.

### CLI

- The `omit_agent_avatar_data_urls` JSON projection layer is removed along
  with the field (`avatar_hash` is 64 chars — fine to print). Mutations
  remain avatar-free, which continues to hit the keep-existing branch.

## Out of scope

- `thread_runtime` list-row slimming (Debt 2) — separate consumer audit.
- Any avatar UI redesign; render surfaces keep their exact appearance.
- Provider icons (`provider_icon` descriptors) and channel plugin icons —
  different system, untouched.

## Impact summary

| Surface | Before | After |
|---|---|---|
| `/api/custom-agents` | 748 KB every fetch | ~28 KB every fetch |
| Avatar bytes | re-sent inline every catalog fetch | fetched once per new hash, then never again |
| `custom-agents.json` | 732 KB, rewritten whole on every store op | ~12 KB + immutable blob files |
| iOS catalog UserDefaults snapshot | ~1 MB main-actor encode | KB-scale |
| Validation authority | none (gateway), 3 inconsistent client caps | single server normalize + caps |

Touched: gateway (model, store, routes, migration, new endpoint) + iOS +
desktop + CLI projection removal. Bot channels/router/bridge untouched
(verified zero consumers).
