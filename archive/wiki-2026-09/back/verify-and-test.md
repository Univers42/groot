# Backend — comment vérifier et tester

Ce doc liste **toutes les façons** de tester le backend, de la plus rapide
(static gates) à la plus complète (live gates + scanner suite + DAST).

## Hiérarchie des tests

```
┌─────────────────────────────────────────────────────────────┐
│  Static gates              — instantané, sans Docker        │
│  ├ make baas-verify-m1    (HEALTHCHECK, IDatabaseAdapter…)  │
│  ├ make baas-verify-m2    (engines wired, Trino catalogs)   │
│  ├ make baas-verify-m3    (outbox migration, relay)         │
│  ├ make baas-verify-m4    (observability declared)          │
│  └ make baas-verify-m5    (WAF, Kong plugins, scanner hooks)│
├─────────────────────────────────────────────────────────────┤
│  Live gates                — stack up requis (5-10 min)     │
│  └ BAAS_VERIFY_LIVE=1 make baas-verify-all                  │
├─────────────────────────────────────────────────────────────┤
│  Security scanner suite    — Docker-only (~10-15 min)       │
│  └ make baas-security-scan                                  │
├─────────────────────────────────────────────────────────────┤
│  DAST                      — stack up requis (5-15 min)     │
│  └ BAAS_VERIFY_SAFE_PORTS=1 make baas-zap                   │
└─────────────────────────────────────────────────────────────┘
```

## Workflow recommandé

### Avant un commit

```bash
# 5 secondes — bloque sur erreur de structure (Dockerfile/SQL/TS)
make baas-verify-all
```

### Avant un PR

```bash
# Lance la suite scanner complète (~10-15 min)
make baas-security-scan

# Si tout est vert, le PR a 90 % de chances de passer la CI
```

### Avant une release

```bash
# Stack up
BAAS_VERIFY_SAFE_PORTS=1 BAAS_VERIFY_NO_WAF=0 make baas-up

# Live gates (rejoue M1 → M5 avec probes runtime)
BAAS_VERIFY_LIVE=1 BAAS_VERIFY_SAFE_PORTS=1 make baas-verify-all

# DAST contre le WAF live
BAAS_VERIFY_SAFE_PORTS=1 make baas-zap

# Cleanup
make baas-down
```

## Variables d'environnement utiles

| Variable | Effet |
|---|---|
| `BAAS_VERIFY_SAFE_PORTS=1` | Remappe tous les ports host sur 1XXXX (évite les conflits avec PG/Mongo locaux). |
| `BAAS_VERIFY_NO_WAF=1` | Skip le WAF (`--scale waf=0`). Plus rapide à monter pour les gates M1-M3. |
| `BAAS_VERIFY_OBSERVABILITY=1` | Active le profile observability (prometheus/grafana/loki/promtail). |
| `BAAS_VERIFY_LIVE=1` | Ajoute le flag `--live` aux verify scripts → probes runtime. |
| `SECURITY_ONLY=semgrep,trivy` | Limite la suite scanner à ces outils. |
| `SECURITY_SKIP=trufflehog` | Inverse : exclut ces outils. |
| `SECURITY_FAIL_LEVEL=critical` | npm audit ne bloque que sur CRITICAL (default: high). |
| `SECURITY_TRIVY_SEVERITY=CRITICAL` | Trivy ne reporte que CRITICAL (default: HIGH,CRITICAL). |
| `SKIP_BUILD=1` | Trivy ne scan que le filesystem, pas les images. |
| `PG_PORT`, `MONGO_PORT`, `REDIS_PORT`, etc. | Override individuel des port-mappings host. |

## Commandes "all-in-one"

### Lance tout d'un coup en local (lourd)

```bash
make baas-down 2>/dev/null || true
BAAS_VERIFY_SAFE_PORTS=1 make baas-up
BAAS_VERIFY_LIVE=1 BAAS_VERIFY_SAFE_PORTS=1 make baas-verify-all
make baas-security-scan
BAAS_VERIFY_SAFE_PORTS=1 make baas-zap
```

Si TOUT est vert, tu as la défense bout en bout :
- M1-M5 verify (static + live)
- Semgrep clean
- npm/pnpm audit clean
- Trivy clean
- TruffleHog clean
- ZAP : 0 High-risk findings

### Quick smoke (rapide, avant un commit)

```bash
make baas-verify-all
```

5 secondes, attrape les vraies régressions structurelles.

## Outputs et artifacts

Chaque scanner écrit son rapport dans :

```
apps/baas/mini-baas-infra/artifacts/security/
├── semgrep.json
├── npm-audit.txt
├── trivy/
│   ├── trivy-fs.json
│   └── trivy-image-<service>.json
├── trufflehog.json
├── zap-baseline.json
├── zap-baseline.html
└── zap-baseline.md
```

`.gitignore` doit exclure ce dossier (sauf le `.gitkeep`) pour ne pas
committer les rapports.

## Diagnostiquer un gate qui plante

Chaque script `verify/mX-*.sh` est conçu pour **fail loud**. Quand il plante,
la dernière ligne `[Mx] FAIL: <raison>` te donne pile l'assertion qui a
explosé. Tu corriges, tu re-relances le même make target.

### Erreurs courantes

| Symptôme | Cause probable | Fix |
|---|---|---|
| `Bind for 127.0.0.1:5432 failed: port is already allocated` | Un PG natif tourne sur le host | `BAAS_VERIFY_SAFE_PORTS=1` ou stopper le PG natif |
| `container mini-baas-waf is unhealthy` | Configs WAF empty | `git restore apps/baas/mini-baas-infra/docker/services/waf/` |
| `dependency failed to start: container mini-baas-kong is unhealthy` | Placeholders `__KONG_CORS_ORIGIN_*__` non substitués | Vérifier `.env` (`KONG_CORS_ORIGIN_APP=https://localhost:3000` etc.) |
| `compose pulls Trivy DB 1GB sur le premier scan` | Normal au 1er run | Patienter ; les runs suivants sont rapides (DB cached) |
| `[M4] FAIL: PrometheusModule not registered` | M4.b en dette | Ajouter `PrometheusModule.register({...})` dans app.module.ts |

## CI mirror

Ce que tu peux lancer en local correspond exactement à ce que la CI lance :

```
.github/workflows/
├── colleague-docker-pipeline.yml    (full stack via Vault)
├── mini-baas-security.yml           (7 jobs : Semgrep, audit, Snyk, Trivy fs+image, TruffleHog, ZAP, Gate)
└── supply-chain.yml                 (npm/pnpm frozen installs, ignore-scripts)
```

Le gate `security-gate` du workflow agrège tous les jobs → si un échoue,
le PR ne peut pas merger.
