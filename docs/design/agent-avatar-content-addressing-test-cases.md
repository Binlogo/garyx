# Test Cases: Content-Addressed Agent Avatars

Design: `docs/design/agent-avatar-content-addressing.md`

Execution rule (owner): every case is actually executed after implementation;
record PASS/FAIL + evidence in the Execution Record column before requesting
review. Headless first; simulator/packaged-app cases are the end-to-end tail.
iOS validation: iPhone 17 Pro Max / iOS 26.5 / light mode only.

## G. Gateway (Rust, headless)

| # | Case | Expectation | Execution Record |
|---|---|---|---|
| G1 | Upsert normalizes and hashes | POST an agent with a large PNG data URL (e.g. 100 KB, 1024px) → stored profile has `avatar_hash` (64-hex), no `avatar_data_url` anywhere in the store file; blob exists at `<data_dir>/avatars/<hash>`; normalized image is ≤256px long edge and ≤ the post-normalize cap | |
| G2 | Three-state merge semantics preserved | PUT with `avatar_data_url` omitted keeps existing hash; PUT with `""` clears to null (blob file remains, orphaned); PUT with a new image replaces the hash | |
| G3 | Same image ⇒ same hash, blob written once | upsert two agents with identical avatar bytes → identical `avatar_hash`, one blob file | |
| G4 | Garbage rejected | upsert with `https://…`, non-image data URL, corrupt base64, or >2 MiB input → 4xx with a clear error; nothing stored (today these were silently stored — this is the validation-authority cutover) | |
| G5 | Avatar endpoint contract | GET `/api/avatars/{hash}` returns bytes with correct sniffed `Content-Type`, `ETag: "{hash}"`, `Cache-Control: public, max-age=31536000, immutable`; unknown hash → 404; unauthenticated → 401 | |
| G6 | Built-in avatars unified | after boot, every built-in profile carries `avatar_hash`; the blobs exist; endpoint serves them; boot is idempotent (second boot writes nothing new) | |
| G7 | Store migration v2→v3 | load a fixture v2 `custom-agents.json` containing (a) a valid large data URL, (b) a garbage string, (c) no avatar → after boot: v3 envelope, (a) has hash + blob, (b) has null hash + warning log, (c) unchanged; file no longer contains `avatar_data_url`; reboot is a no-op | |
| G8 | List response shape | GET `/api/custom-agents` rows carry `avatar_hash` (null allowed), never `avatar_data_url`; measure response size with the real profile set (expect ~28 KB vs 748 KB) | |
| G9 | Normalize idempotence | normalize(normalize(x)) is byte-identical for PNG and JPEG outputs → re-uploading a downloaded avatar yields the same hash | |
| G10 | Rust regression | `cargo test -p garyx-gateway --lib` and `-p garyx-models` full green | |

## I. iOS (headless first)

| # | Case | Expectation | Execution Record |
|---|---|---|---|
| I1 | Known hash ⇒ zero requests | seed the avatar store with hash H; render a catalog/agent row with `avatar_hash: H` → image renders from disk; mocked transport observes **zero** `/api/avatars/*` requests | |
| I2 | Unknown hash ⇒ exactly one async fetch | render N rows referencing the same unknown hash concurrently → exactly one `GET /api/avatars/{hash}`; all rows refresh when it lands; blob persisted; second cold render hits I1 | |
| I3 | Fetch never blocks render | with the avatar transport gated (held open), rows render immediately with the provider/initials fallback; releasing the gate swaps the image in | |
| I4 | Failure is silent + lazily retried | avatar endpoint 500s → no error UI, fallback stays; a later render triggers a fresh attempt which succeeds | |
| I5 | Catalog snapshot slimmed | `GaryxCachedAgent` carries `avatarHash` only; snapshot version 7; a stored v6 snapshot is discarded cleanly; persisted snapshot for the real profile set is KB-scale (assert < 64 KB) | |
| I6 | Widget channel | widget projection passes scope+hash; widget process loads bytes from the shared App Group store; no inline base64 in App Group UserDefaults payloads | |
| I7 | Shared image dedup | two agents with the same `avatar_hash` store one blob and both render | |
| I8 | Upload read-back | avatar upload flow saves, reads back the server hash, and the next render is a disk hit (zero avatar fetches); a deliberately mismatched local normalization falls back to the fetch path | |
| I9 | Auth in headers | the avatar fetch carries the Authorization header; the hash URL contains no token material | |
| I10 | Regression | full `GaryxMobileCoreTests` SwiftPM suite + Home/`GaryxMobileTests` suites green; #TASK-2798 B-suite and #TASK-2806 R/P/C suites unaffected | |
| I11 | Cache is gateway-independent (owner rule) | fetch hash H while connected to gateway profile A; switch to gateway profile B (different URL — same or different backend) whose catalog also references H → renders from disk with **zero** avatar requests; store contains one record for H with no scope dimension in its key | |

## D. Desktop (headless first, then packaged check)

| # | Case | Expectation | Execution Record |
|---|---|---|---|
| D1 | Wire mapping | agents list maps `avatar_hash` → `avatarHash`; create/update still send `avatar_data_url`; contract types compile with the field removed | |
| D2 | Known hash ⇒ zero requests | resolver cache seeded → rendering agent rows issues no avatar fetches (assert via mocked fetch layer) | |
| D3 | Unknown hash ⇒ one deduped fetch | multiple components requesting the same hash concurrently → one fetch, all resolve; object URL cached; persistent layer survives renderer reload | |
| D4 | Fallback + swap | unknown hash renders `ProviderAgentIcon`/initials immediately, swaps when the fetch lands | |
| D5 | Auth in headers | avatar fetch uses the authenticated client path; no token in the URL | |
| D6 | Renderer regression | desktop unit/component suites green; agent picker, thread rail, pinned sidebar, search dialog, task tree, automation dialog, agents hub all render avatars (visual spot-check list from the consumer survey) | |
| D7 | Packaged-app check | `npm run dist:dir`, open installed app, attach CDP: avatars render across the surfaces above; network panel shows avatar fetches only for first-seen hashes and none on subsequent navigation | |
| D8 | Cache is gateway-independent (owner rule) | resolve hash H under gateway profile A, switch the app to profile B referencing H → zero avatar fetches; persistent cache key carries no gateway/scope dimension | |

## E. End-to-end (real gateway)

| # | Case | Expectation | Execution Record |
|---|---|---|---|
| E1 | Cold start after migration | real (copied) data dir with the 732 KB v2 store → boot migrates to v3; iOS simulator cold start: catalog fetch is ~28 KB; avatar fetches happen once per distinct hash (proxy trace), total avatar bytes ≤ ~60 KB for the 11-agent set | |
| E2 | Second launch ⇒ silence | relaunch the app: proxy trace shows **zero** `/api/avatars/*` requests (the owner's headline rule, end to end) | |
| E3 | Avatar change propagates | change one agent's avatar on desktop → iOS next catalog refresh carries the new hash → exactly one fetch for the new hash; old cached blob untouched | |
| E4 | TestFlight-independent | no TestFlight/release coupling introduced (per repo rule; release is a separate explicit ask) | |

## M. Review contract notes

- Review scope: the avatar pipeline (contract, normalize, migration, both
  client caches) + the consumer surfaces listed in the survey. Adjacent
  pre-existing issues go to the debt doc, not into this loop.
- The three-state upsert semantics (G2) and the CLI keep-existing behavior
  are regression contracts, not new behavior — verify they still hold.
