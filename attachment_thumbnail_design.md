# Server-Side Attachment Thumbnails — Design Specification

**Status:** Draft for review (no implementation)
**Scope of this doc:** Server-side thumbnail *generation, storage, and API*. The
frontend lightbox/preview work and the "clickable content images" work are
tracked separately and only consume the API described here.

---

## 1. Goals & non-goals

### Goals
- Generate a small thumbnail for **image** attachments (and, optionally,
  **video** attachments) stored on the **local disk** backend.
- Persist thumbnails on the local disk **in parallel** to the original file —
  no S3/fog dependency.
- Expose a thumbnail via a new, access-controlled **API endpoint** plus a
  HAL **link** on the attachment representer, so the Files tab can render real
  thumbnails instead of a generic MIME icon.
- Degrade gracefully: if a thumbnail cannot be produced (unsupported type,
  generation failure, tooling absent, fog storage), the API simply advertises
  **no thumbnail link** and the UI keeps the current icon.

### Locked decisions (this revision)
- **Images only in v1.** Video poster frames are *designed* (§6) but **not
  shipped**; the ffmpeg path stays off by default. Video still previews in the
  lightbox via `/content`.
- **Generation = eager + lazy** (§3, §7): background job on upload *and* an
  on-demand fallback that also backfills old attachments with no migration.
- **A `thumbnail_status` column is added** (§10): one migration; drives precise,
  cheap API gating and prevents retrying failed/unsupported files.
- This doc lives at the repo root alongside the other fork specs.

### Non-goals
- No thumbnails for fog/S3-backed deployments in this iteration (see §11).
- No new image-processing service for PDFs or office documents.
- No change to the existing `/content` endpoint or its inline-display behavior.
- The lightbox itself: it uses the existing full-size `/content` URL, **not**
  a thumbnail. Thumbnails exist only for the list/grid view.

---

## 2. Current state (reference)

| Concern | Where | Notes |
|---|---|---|
| Attachment storage (local) | [local_file_uploader.rb:48](app/uploaders/local_file_uploader.rb#L48) | `store_dir = attachments_storage_path/<model>/file/<id>` |
| Local disk path of original | [attachment.rb](app/models/attachment.rb) `#diskfile` | returns the on-disk `File` |
| Inline serving + disposition | [attachment.rb:112](app/models/attachment.rb#L112), [attachment.rb:144](app/models/attachment.rb#L144) | images/video/pdf/text → `Content-Disposition: inline` |
| Content endpoint | [attachments_api.rb:63](lib/api/v3/attachments/attachments_api.rb#L63), [attachment_renderer.rb](lib/api/helpers/attachment_renderer.rb) | `namespace :content`, `sendfile diskfile.path` |
| HAL links | [attachment_representer.rb:75](lib/api/v3/attachments/attachment_representer.rb#L75) | `staticDownloadLocation`, `downloadLocation`, `delete` |
| Type predicates | [attachment.rb:153](app/models/attachment.rb#L153) | `is_image?`, `is_movie?`, `is_pdf?`, `is_text?` |
| Post-upload async hook | [attachment.rb:75](app/models/attachment.rb#L75), [attachment.rb:270](app/models/attachment.rb#L270) | `after_commit :enqueue_jobs, on: :create` → `ExtractFulltextJob`, `VirusScanJob` |
| Backfill precedent | [attachments.rake:110](lib/tasks/attachments.rake#L110) | `extract_fulltext_where_missing` |
| Image tooling | [Gemfile:216](Gemfile#L216) | `mini_magick ~> 5.3` already present |

**Key facts that shape the design**
- Attachments are CarrierWave-mounted (`mount_uploader :file`), **not**
  ActiveStorage — there is **no built-in variant/representation facility**, so
  thumbnails must be generated and cached by us.
- `mini_magick` is already a dependency (ImageMagick must be present, which it
  already is for PDF export). **No new gem needed for images.**
- A digest column (`md5`) exists per attachment — usable as a cache/ETag key.
- There is already an after-create async pipeline we can extend.

---

## 3. High-level design

```
upload ──after_commit──▶ enqueue_jobs ──▶ Attachments::GenerateThumbnailJob (async)
                                               │
                                               ├─ image? ─▶ mini_magick resize ─┐
                                               └─ movie?  ─▶ ffmpeg poster ──────┤
                                                                                 ▼
                                            write to  <thumbnails_path>/<id>/<variant>.<ext>
                                                                                 │
GET /api/v3/attachments/:id/thumbnail ◀── representer link `thumbnail` ◀─────────┘
        │
        ├─ exists  → sendfile thumbnail (Content-Disposition: inline, cached)
        └─ missing → generate on-demand (lazy fallback) OR 404
```

Two generation triggers, both writing to the same cache location:
1. **Eager (preferred):** a background job enqueued on upload, mirroring
   `ExtractFulltextJob`. Keeps the request path fast and the upload path
   unburdened.
2. **Lazy fallback:** if a thumbnail is requested but missing (e.g. attachment
   predates the feature, or the job hasn't run yet), generate it inline at the
   endpoint with a hard timeout, then cache. This also makes **backfill free**
   for existing attachments without a migration.

> **D1 — DECIDED: both.** Eager for new uploads, lazy as the safety net and as
> the zero-migration backfill path for pre-existing attachments.

---

## 4. Thumbnail storage layout

Thumbnails are **derived, disposable** artifacts. They are stored on local disk
under a dedicated, safely-wipeable subtree, parallel to originals:

```
<attachments_storage_path>/
├── attachment/file/<id>/<original-filename>        # existing original
└── _thumbnails/<id>/<variant>.webp                 # NEW
```

- Path helper lives on the model, e.g. `Attachment#thumbnail_path(variant:)`,
  resolved from `OpenProject::Configuration.attachments_storage_path`.
- The `_thumbnails` prefix is chosen so it never collides with a model name
  (CarrierWave `store_dir` is `<model>/file/<id>`; `_thumbnails` is not a model).
- Because they are derivable, the directory can be deleted wholesale at any time
  and will regenerate lazily. This is the recovery story for corruption.

**Variants:** start with a **single** variant for the list view:

| Variant | Bounding box | Format | Purpose |
|---|---|---|---|
| `card` | 240×240 (fit inside, no upscale) | **WebP** q≈75 | Files tab / grid |

**D2/D7 — DECIDED:** a single `card` variant in **WebP**. A `medium` variant is
**deferred**; the lightbox uses the original `/content` URL. WebP is universally
supported by the browser targets this fork runs on.

---

## 5. Image thumbnail generation

- Use `mini_magick` on `attachment.diskfile.path`.
- Pipeline: auto-orient (honor EXIF) → strip metadata → resize-to-fit within the
  bounding box (never upscale) → encode WebP.
- Guard rails:
  - Only when `attachment.is_image?` **and** the source is a raster format
    ImageMagick can decode. **D3 — DECIDED: SVG is NOT thumbnailed** — it is
    treated as non-thumbnailable (`thumbnail_status` → `unsupported`), shows the
    media icon in lists, and still previews via `/content` in the lightbox. This
    avoids serving user-authored markup as a preview and needs no librsvg.
  - Enforce a **max source dimension / pixel budget** before decoding to avoid
    decompression bombs (ImageMagick `-limit` + a pre-check on identified
    geometry). Reject oversized inputs → no thumbnail.
  - Wrap in a timeout; on any failure log and record "no thumbnail" (see §10).

## 6. Video thumbnail generation (DESIGNED, NOT SHIPPED in v1)

> **D4 — DECIDED: images only in v1.** The ffmpeg path below is specified so the
> later addition is a config flip + worker branch, but v1 ships with video
> thumbnails **disabled** (`ffmpeg_path` defaults to nil). `thumbnailable?`
> therefore returns false for video in v1, and video attachments advertise no
> thumbnail link.

Constraint from review: **ffmpeg is acceptable, but must add no burden to RPM/
DEB packaging or installation.** Therefore ffmpeg is treated as an **optional,
runtime-detected** capability — never a hard build/runtime dependency:

- Detection: probe for the `ffmpeg` binary once (cached), e.g. via a configured
  path or `which`. Expose as `OpenProject::Configuration.ffmpeg_path` (nil =
  disabled). **No gem, no native extension, nothing added to the package spec.**
- If ffmpeg is **absent**: video attachments simply get **no thumbnail link**
  (UI shows the media icon; video still previews in the lightbox via `/content`).
- If present: extract a single poster frame (e.g. at ~1s or 10% of duration)
  with `ffmpeg -ss <t> -i <file> -frames:v 1`, pipe into the same WebP resize
  step used for images.
- Same pixel/timeout guard rails as images.

> Packaging note to verify with ops: the official Docker image and the
> packaged installers must continue to build/install **unchanged** when ffmpeg
> is not bundled. This design assumes ffmpeg is opportunistically used if the
> host happens to provide it, and the feature is otherwise a no-op for video.
> (Decision point D4: do we want video thumbnails at all in v1, or images only?)

---

## 7. Generation orchestration (jobs & model)

Mirror the existing fulltext pipeline:

- Extend `Attachment#enqueue_jobs` ([attachment.rb:270](app/models/attachment.rb#L270))
  to also enqueue `Attachments::GenerateThumbnailJob.perform_later(id)` when the
  attachment `thumbnailable?` (new predicate: `is_image?` or
  (`is_movie?` and ffmpeg available)).
- New worker `Attachments::GenerateThumbnailJob < ApplicationJob`
  (`app/workers/attachments/`):
  - Loads the attachment, re-checks visibility-independent preconditions, skips
    if a fresh thumbnail already exists (keyed by digest), generates + writes.
  - Idempotent and safe to re-run.
- New predicate(s) on the model: `thumbnailable?`, `thumbnail_ready?`,
  `thumbnail_path(variant:)`, `generate_thumbnail!(variant:)`.
- New rake task `attachments:generate_thumbnails_where_missing` for bulk
  backfill, modeled on `extract_fulltext_where_missing`
  ([attachments.rake:110](lib/tasks/attachments.rake#L110)).

**Virus-scan / quarantine gating:** generation must not run on, and the endpoint
must never serve, a thumbnail for an attachment that is `status_quarantined?` or
`pending_virus_scan?`. Reuse the same checks as `validate_attachment_access!`
([attachment_renderer.rb:71](lib/api/helpers/attachment_renderer.rb#L71)).

---

## 8. API changes

### 8.1 New endpoint

Add a `:thumbnail` namespace alongside `:content` in
[attachments_api.rb:63](lib/api/v3/attachments/attachments_api.rb#L63), inside
the existing `route_param :id` block (so it inherits the visibility
`after_validation`):

```
GET /api/v3/attachments/:id/thumbnail
```

Optional future query/segment for variant selection — **deferred** while there
is a single variant. If added later: `?size=card|medium`.

Behavior:
| Condition | Response |
|---|---|
| Not visible to user | `404` (same as content) |
| Quarantined / pending scan | `404` (do not leak existence/preview) |
| Not thumbnailable (e.g. PDF, doc) | `404` |
| fog/external storage | `404` (v1: no thumbnails for fog) |
| Thumbnail exists | `200`, `sendfile`, `Content-Type: image/webp`, `Content-Disposition: inline`, `X-Content-Type-Options: nosniff`, cache headers + `ETag` from digest |
| Thumbnailable but missing | D1: lazy-generate then `200`; or `404`/`202` if eager-only |

The endpoint reuses the `AttachmentRenderer` helpers (cache headers, nosniff,
sendfile) but serves the **thumbnail path**, not `diskfile.path`. A small
parallel helper (e.g. `respond_with_thumbnail`) or a parameterization of
`send_attachment` is needed.

### 8.2 New HAL link

Add to [attachment_representer.rb](lib/api/v3/attachments/attachment_representer.rb),
rendered **only when a thumbnail is applicable** so the client can branch
cleanly:

```ruby
link :thumbnail,
     cache_if: -> { represented.thumbnail_status == "ready" } do
  { href: api_v3_paths.attachment_thumbnail(represented.id) }
end
```

- Add `attachment_thumbnail(id)` to `API::V3::Utilities::PathHelper`.
- **D5 — DECIDED (readiness):** because the `thumbnail_status` column exists, the
  link is gated on `status == "ready"` — a pure column read, no per-attachment
  disk stat during list serialization. The link appears once generation has
  completed (eager job typically finishes within seconds of upload; a client
  that fetched before then sees no link and re-fetches, or the list re-renders).
- Trade-off vs. gating on applicability: a freshly uploaded image briefly lacks
  a link until the job runs. Acceptable; avoids advertising a link that would
  trigger slow lazy generation on the very first list render. (If we later want
  the link to appear immediately, switch the gate to `thumbnailable?` and let
  the endpoint lazy-generate.)

### 8.3 Backward compatibility
- Purely additive: a new link + new endpoint. Existing clients ignore the link.
- `staticDownloadLocation` / `downloadLocation` / `/content` are unchanged.

---

## 9. Security & access control

- The endpoint lives **inside** the existing `route_param :id` `after_validation`
  that enforces `@attachment.visible?(current_user)` — so authz is inherited.
- Quarantine / pending-scan gating as in §7.
- Always serve thumbnails as `image/webp` with `X-Content-Type-Options: nosniff`;
  never echo the original content-type. The thumbnail is always a re-encoded
  raster we produced, never the user's bytes verbatim (eliminates SVG/script
  smuggling via the preview).
- Decompression-bomb limits on generation (§5).
- Path construction from integer `id` only (no user-controlled path segments).

---

## 10. Failure handling & "negative" caching

> **D6 — DECIDED: `thumbnail_status` column.** One migration.

A new nullable column on `attachments` tracks derivation state:

| `thumbnail_status` | Meaning | Set by |
|---|---|---|
| `nil` | Not yet considered (legacy rows, or non-thumbnailable) | default |
| `pending` | Job enqueued / not finished | `enqueue_jobs` |
| `ready` | A valid thumbnail exists on disk | generation success |
| `unsupported` | Type can't be thumbnailed (e.g. CMYK TIFF we won't decode) | generation |
| `error` | Generation attempted and failed | generation (with log) |

Consequences:
- The lazy path only attempts generation when status ∈ {`nil`, `pending`}; it
  will **not** keep retrying `unsupported`/`error` rows on every request.
- The representer gates the link on `thumbnail_status == "ready"` — a pure
  column read, no disk stat during list serialization (resolves D5 below).
- A column value is cheaper and more reliable than a sentinel file and survives
  a wipe of the `_thumbnails` tree (after a wipe, set `ready`→`nil` via the rake
  task to force regeneration, or compare digests).

---

## 11. fog / external storage

v1 explicitly **does not** generate thumbnails for fog-backed attachments:
- `thumbnailable?` returns false when `external_storage?`.
- Rationale: generating would require downloading each original to a temp file,
  re-uploading the derivative, and managing its lifecycle in the bucket — out of
  scope and against the "local disk, in parallel" directive.
- Behavior is identical to "no thumbnail": UI shows the icon, lightbox still
  works via the redirected `/content`.

(If fog support is wanted later, the cleanest path is generate-on-demand to a
local cache dir keyed by digest, served by our app — documented as a follow-up.)

---

## 12. Lifecycle & operations

- **Deletion:** when an attachment is destroyed, delete its `_thumbnails/<id>/`
  directory. Hook into the existing destroy callback chain.
- **Regeneration:** thumbnails are keyed by digest; if an attachment's content
  could change (generally it cannot — attachments are immutable once stored),
  a digest mismatch triggers regeneration. Manual recovery: delete the
  `_thumbnails` subtree and re-run the rake task.
- **Disk usage:** one small WebP (~5–30 KB) per image attachment. Bounded and
  small relative to originals. Worth a one-line note in the admin docs.
- **Config knobs (proposed):**
  - `attachments_thumbnails_enabled` (default true)
  - `ffmpeg_path` (default nil → video thumbnails disabled)
  - reuse `attachments_storage_path` for location (no new path setting).

---

## 13. Decisions

### Locked
| # | Decision | Outcome |
|---|---|---|
| D1 | Generation timing | **Both** eager job + lazy on-demand fallback |
| D4 | Video thumbnails in v1 | **Images only**; ffmpeg path designed, off by default |
| D5 | Representer link gating | **Readiness** (`thumbnail_status == "ready"`) |
| D6 | Failure/negative caching | **`thumbnail_status` column** (one migration) |
| — | Doc location | **Repo root** |

| D2 | Variants | **`card` only** (~240px); `medium` deferred |
| D3 | SVG handling | **No thumbnail** — `unsupported`, icon + lightbox via `/content` |
| D7 | Thumbnail format | **WebP** q≈75 |
| — | Container scope | **All containers** (work packages, wiki, messages, …) |

All design decisions are now resolved. See §16 for the few operational defaults
adopted without an explicit decision (cache TTL, edition, concurrency).

---

## 16. Operational defaults (adopted; flag if any should change)

These were not raised as explicit decisions; the design adopts the following
sensible defaults. Call out any you want changed.

- **Container scope — all containers.** Because `Attachment` is shared,
  thumbnails appear wherever an attachment list is rendered (work packages,
  wiki, messages, …). No per-container gating in v1.
- **Cache TTL.** Thumbnails are immutable per digest, so the endpoint advertises
  a long-lived, immutable cache (`Cache-Control: public, max-age=31536000,
  immutable`) plus an `ETag` from the digest.
- **Edition.** Community / always-on. Not Enterprise-gated.
- **Concurrency & limits.** `GenerateThumbnailJob` runs on the normal GoodJob
  queue; source images beyond a pixel/byte budget are rejected (→ `unsupported`)
  to bound CPU/memory. No separate disk quota for `_thumbnails` (artifacts are
  small and regenerable).

## 14. Testing plan (for the implementation phase)

- **Model:** `thumbnailable?`, path resolution, generation produces a valid WebP
  within bounds, EXIF orientation honored, oversized input rejected, video path
  no-ops without ffmpeg.
- **Job:** idempotency, skip-if-fresh, quarantine/pending gating.
- **Request specs (API):** 404 for not-visible / quarantined / non-thumbnailable
  / fog; 200 + correct headers for a ready image; lazy-generation path; ETag /
  caching behavior.
- **Representer:** link present iff `thumbnailable?` and not fog.
- **Security:** nosniff + `image/webp` always; decompression-bomb input rejected.
- **Rake backfill:** generates only for missing, respects gating.

---

## 15. Affected files (anticipated)

- `app/models/attachment.rb` — predicates, paths, `enqueue_jobs` extension,
  destroy cleanup. (+ migration if D6 = column)
- `app/workers/attachments/generate_thumbnail_job.rb` — **new**
- `app/services/attachments/` — **new** generation service (image + optional video)
- `lib/api/v3/attachments/attachments_api.rb` — `:thumbnail` namespace
- `lib/api/v3/attachments/attachment_representer.rb` — `thumbnail` link
- `lib/api/v3/utilities/path_helper.rb` — `attachment_thumbnail`
- `lib/api/helpers/attachment_renderer.rb` — thumbnail serving helper
- `config/constants/settings/definition.rb` — new settings (D-dependent)
- `lib/tasks/attachments.rake` — backfill task
- specs mirroring the above
```
