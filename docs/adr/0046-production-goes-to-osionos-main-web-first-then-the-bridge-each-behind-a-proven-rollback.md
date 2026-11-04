# 0046. Production goes to osionos main web first, then the bridge, each behind a proven rollback

- Status: proposed (devil: BLOCK now, PROCEED-WITH-CONDITIONS G1–G16 once G1–G6 hold, 2026-11-04)
- Date: 2026-11-04
- Deciders: devil (ruling); owner (production is `main`); the night operator lives with it

## Context

- `origin/develop` aebe75df CI is red (shard 6/6, stub bridge). PR #297 is open and green at dcd80bda,
  which contains aebe75df (`gh pr checks 297`).
- ADR 0041:42 and :67 require Firefox, Safari, U6, R-U1 and R-U2 before `main`. None is measured.
- The bridge's rendered config hash `91df09c4…` ≠ the running `d08c238f…`. Env, image, volumes and
  memory limit match, and the cause is unknown (`dc.sh config --hash osionos-bridge` under the four
  overlays plus `OSIONOS_PUBLISH_SOCKET_DIR`).
- From 904b9a0e to develop, the bridge gains 422 content validation on page and database writes.
  It used to coerce (`bridge-api.mjs` diff at the `validatedPageContent` sites). There are no
  migrations or new tables. Sessions and step-up state survive a restart (`bridge-sessions.mjs:53`,
  Redis).
- Media signing is inert without `MEDIA_URL_SECRET`, which is unset in production
  (`bridge-media-sign.mjs`).
- The proxy (`ab7b4692…`) and app (`59cfc758…`) hashes match their running labels.
- Unknown when this was written: the drifting bridge field; how the client behaves on a 422 save;
  whether stored rows pass the validator.

## Decision

The #174 proxy recreate goes on its own, under its hash precondition. osionos then ships in this
order: develop green → main fast-forward → the web from main with `VITE_WHITEBOARD_APP_URL` → the
bridge from main, image only → the bridge with `livekit-tls.yml`. Each step is a separate recreate
with a written, hash-proven rollback. The bridge goes only after its drift is explained, stored
data passes the new validator, and a backup has been read back.

## Alternatives considered

- **The bridge first, or the bridge and web together:** the combination of the old web
  adc07efc and the new bridge has run nowhere. The beta has proven only the new web on the old
  bridge. With both at once, a failure has two suspects.
- **Recreate the bridge despite the hash mismatch:** the rollback target would be a config
  nobody has seen run. This is the ADR 0032 failure class.
- **Waive ADR 0041's main gates for the night:** an agent cannot give the owner's waiver, and
  the gates are measurable tonight with Playwright Firefox and WebKit.

## Consequences

- Conditions G1–G16, the order and the per-step rollback are in
  `docs/ops/production-golive-verdict-2026-11-04.md`. ADR 0043 D1–D12 still bind the web step;
  its D12 ("not tonight: the bridge") is lifted by this ruling only under G4–G6 and G11–G14.
- #233/#235 are not closed by this deploy; signing starts only when `MEDIA_URL_SECRET` is set,
  which is a separate step.
- "Remember this computer" goes live for production and the beta together (R5 override).
- Revisit this ADR if develop adds a migration or a storage-format change, or if the bridge is
  built from anything but S.
