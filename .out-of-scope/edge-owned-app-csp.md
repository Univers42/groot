# The groot edge owning the osionos app CSP is out of scope

- Decided: 2026-11-22 · by devil (ADR 0076, RULING-314 §2)
- Holds while: the web image is the unit of promotion (ADR 0043)

## The concept

Set the app's Content-Security-Policy in the groot edge nginx (`tls/nginx.conf`, the beta edge) instead of the app image.

## Why not

- The web image is promoted alone. An edge policy describes whatever build the edge was configured for, not the build it is serving, so a new inline script or worker ships blocked or unpoliced.
- The edge adds `frame-ancestors` only when the upstream sent no CSP (S2), so one owner remains.

## Reopen when

The web image stops being the unit of promotion, for example when the edge and the app ship as one release.
