# Data Integrity Safeguards — platform / infrastructure (cross-cutting)

> `restore-if-empty.sh` guarantees that the all-engine demo-data restore is executed only when every running primary engine is confirmed empty, and aborts silently whenever any engine contains data or returns an unreadable probe result.

## What it is (the concept)

**Data integrity safeguards** are controls that prevent authorised but destructive operations from overwriting or corrupting existing data. Here the specific pattern is a **fail-safe default**: the restore path is disabled unless a positive, per-engine emptiness proof succeeds. The complementary principle is **fail-closed on uncertainty**: an unreadable probe result (`?`) is treated identically to a populated engine and blocks the restore just as firmly as confirmed data would.

## What it defends against

See [data-integrity-safeguards](../../attack/data-integrity-safeguards.md).

A re-run of `make all` on a machine with live tenant data would, without this control, unconditionally overwrite every primary engine (Postgres, MySQL, MongoDB) with the bundled demo snapshot. The threat is operator error or automated re-provisioning wiping real user data, workspace pages, or activity logs. In the Track Binocle stack this is especially acute because `make all` is designed to be idempotent and is routinely re-run after code changes.

## How platform implements it

The control lives entirely in [`scripts/restore-if-empty.sh`](../../../../scripts/restore-if-empty.sh), wired unconditionally into the `make all` recipe (confirmed in `CLAUDE.md`: `all: … restore-if-empty …`).

**Engine health gate before any probe** — the script blocks until each engine container reports `healthy` (or has no healthcheck) before issuing any count query. This prevents a transient "not ready" state from being misread as an uncertain probe and incorrectly skipping the restore on a genuinely fresh machine:

```sh
# lines 21-31
wait_healthy() {
    …
    while [ "$i" -lt 90 ]; do
        st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" …)
        case "$st" in healthy | none) return 0 ;; esac
        …
    done
}
```

**Fail-closed `gate()` function** — any count greater than zero, or a non-numeric/empty probe result (`?`), immediately flips `EMPTY=0`. Once flipped it is never re-raised:

```sh
# lines 38-45
gate() {
    [ "$EMPTY" = 1 ] || return 0
    case "$2" in
        0) : ;;
        '?') EMPTY=0; REASON="$1 unreadable" ;;
        *) if numeric "$2" && [ "$2" -gt 0 ]; then EMPTY=0; REASON="$1 has data ($2)"; fi ;;
    esac
}
```

**Per-engine probes** (`pg_probe`, `mysql_probe`, `mongo_probe`) each handle the case where their engine container is not running (returns early without failing the gate) and pass `?` to `gate()` if the query itself fails or returns a non-numeric result:

- **Postgres** (`pg_probe`, lines 47-60): checks `to_regclass('public.osionos_pages')` before issuing a `count(*)`, avoiding a parse error on a schema-less fresh instance.
- **MySQL** (`mysql_probe`, lines 62-70): counts tables in the `ops` schema via `information_schema`.
- **MongoDB** (`mongo_probe`, lines 72-81): counts documents in `activity.events`.

**Restore only on total confirmed emptiness** — the destructive `restore-databases.sh` is called only inside the `EMPTY=1` branch:

```sh
# lines 92-101
if [ "$EMPTY" = 1 ]; then
    note "all running primary engines empty → restoring the full snapshot (all engines)…"
    CONFIRM=1 "$RESTORE"
    …
else
    note "data present ($REASON) — skipping restore (no wipe)."
fi
```

The `CONFIRM=1` environment variable is the explicit confirmation flag required by `restore-databases.sh`; it is never set unconditionally outside this guarded branch.

## How we know it is applied

The `CLAUDE.md` at the repo root documents the `all` recipe verbatim:

```
all: sync-submodules-soft secrets-ensure certs certs-trust-local backend-up env-local-ensure restore-if-empty frontends-up healthcheck showcase
```

The target name `restore-if-empty` maps directly to the script. The script's own header comment repeats the guarantee: *"Wired into `make all` (and `make bootstrap`)."* The `else` branch at line 100 emits a log line (`[restore-if-empty] data present (…) — skipping restore (no wipe).`) that is observable in `make all` output on any non-empty stack, providing a live runtime signal that the guard fired.

## Reference

OWASP Top 10 A08:2021 — Software and Data Integrity Failures:
`https://owasp.org/Top10/A08_2021-Software_and_Data_Integrity_Failures/`

(Network access to owasp.org was blocked in this environment; the URL is the canonical slug published by OWASP for A08:2021 and is stable across OWASP documentation.)

## Residual risk / assumptions

- **MSSQL and MinIO are not probed.** The script waits for `mini-baas-mssql` and `mini-baas-minio` health but issues no count query against them. Data in those engines does not block the restore.
- **Single-engine trust boundary.** Each probe checks one table or schema per engine; data in other schemas or databases within the same engine instance is not counted and would not trigger the guard.
- **`CONFIRM=1` is the only restore gate.** If `restore-databases.sh` is invoked directly (outside this wrapper) without `CONFIRM=1` it may behave differently; this script does not patch or lock the restore binary itself.
- **Container exec access.** The probes rely on `docker exec` into running containers. If container exec is disabled by policy or the daemon is inaccessible, all probes return `?`, `EMPTY` is set to `0`, and the restore is skipped — the fail-closed default holds.
- **Not a substitute for backups.** This control prevents accidental restore overwrites during `make all`; it provides no protection against data loss caused by other mechanisms (dropped tables, disk failure, or manual `psql` commands).
