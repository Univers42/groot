#!/usr/bin/env bats
# The Mail and Calendar static previews on the second Funnel node: `up apps`, the main node's map
# staying untouched, and one red/green pair per apps check (exposure2, nobridge, nodev, apphdrs,
# bundle2, appurls, appenv). Stubs: public-funnel-helpers.bash.
# Caveat: the curl and docker stubs answer what the checks ask; whether a real nginx sends those
# headers is measured by the scratch-compose matrix in the PR, not here.
# `has`/`lacks`, never `! cmd`: a negation that is not the last line never fails a bats test.

bats_require_minimum_version 1.5.0

load public-funnel-helpers

@test "the main FUNNEL_MAP is unchanged and the apps map is the second node's alone" {
  grep -qx 'FUNNEL_MAP="443:4322 8443:3001 10000:4000"' "$SCRIPT"
  grep -qx 'APPS_FUNNEL_MAP="443:3102 8443:3103"' "$BATS_TEST_DIRNAME/../lib/public-tailnet.sh"
}

@test "up apps opens 443 and 8443 on the apps node only, after verify --pre, then verifies" {
  : >"$T/funnel-apps"
  run_pf up apps
  [ "$status" -eq 0 ]
  [ "$(funnel_calls)" -eq 0 ]
  [ "$(apps_funnel_calls)" -eq 2 ]
  grep -qx '\[apps\] funnel --bg --https=443 https+insecure://127.0.0.1:3102' "$T/ts.log"
  grep -qx '\[apps\] funnel --bg --https=8443 https+insecure://127.0.0.1:3103' "$T/ts.log"
  has "PASS  exposure2"
  has "verify (full):"
  lacks "FAIL"
}

@test "up apps dies before opening anything when the apps origins are not set" {
  : >"$T/funnel-apps"
  set_env PUBLIC_MAIL_ORIGIN ""
  set_env PUBLIC_CALENDAR_ORIGIN ""
  run_pf up apps
  [ "$status" -ne 0 ]
  has "PUBLIC_MAIL_ORIGIN"
  has "PUBLIC_CALENDAR_ORIGIN"
  [ "$(apps_funnel_calls)" -eq 0 ]
  [ ! -s "$T/funnel-apps" ]
}

@test "up apps opens nothing when verify --pre fails" {
  : >"$T/funnel-apps"
  chmod 644 "$T/repo/.env.public"
  run_pf up apps
  [ "$status" -ne 0 ]
  has "Funnel stays closed"
  [ "$(apps_funnel_calls)" -eq 0 ]
}

@test "up apps resets the apps node when the post-open verify fails" {
  : >"$T/funnel-apps"
  TLS_RC=35 run_pf up apps
  [ "$status" -ne 0 ]
  has "FAIL  tls2"
  grep -qx '\[apps\] funnel reset' "$T/ts.log"
  [ ! -s "$T/funnel-apps" ]
}

@test "exposure2 passes on exactly 443 and 8443 onto 3102 and 3103" {
  run_pf verify apps
  [ "$status" -eq 0 ]
  has "PASS  exposure2      apps node osionos-apps.tail10f2ea.ts.net.: funnel 443,8443 -> 443 / 127.0.0.1:3102,8443 / 127.0.0.1:3103"
}

@test "exposure2 FAILs on a third port, a wrong target, a closed Funnel and a wrong DNS name" {
  echo "10000 4000" >>"$T/funnel-apps"
  run_pf verify apps
  [ "$status" -eq 1 ]
  has "FAIL  exposure2      apps node funnel ports '443,8443,10000'"
  printf '443 3102\n8443 3001\n' >"$T/funnel-apps"
  run_pf verify apps
  has "FAIL  exposure2      apps node funnel ports '443,8443' -> '443 / 127.0.0.1:3102,8443 / 127.0.0.1:3001'"
  : >"$T/funnel-apps"
  run_pf verify apps
  has "FAIL  exposure2      apps node osionos-apps.tail10f2ea.ts.net. has its Funnel closed"
  printf '443 3102\n8443 3103\n' >"$T/funnel-apps"
  TSA_DNS=other.tail10f2ea.ts.net. run_pf verify apps
  has "FAIL  exposure2      apps node DNS name is 'other.tail10f2ea.ts.net.'"
}

@test "exposure2 FAILs a missing node when origins are set and SKIPs it when they are not" {
  rm "$T/apps-node"
  run_pf verify apps
  [ "$status" -eq 1 ]
  has "FAIL  exposure2      the apps node is not running"
  set_env PUBLIC_MAIL_ORIGIN ""
  set_env PUBLIC_CALENDAR_ORIGIN ""
  run_pf verify
  has "SKIP  exposure2      apps not deployed"
  lacks "FAIL"
}

@test "nobridge passes, then FAILs on a bridge container and on a Funnel target of 4100 or 4200" {
  run_pf verify --pre
  has "PASS  nobridge"
  printf 'mail-web\ncalendar-web\nmail-bridge\n' >"$T/ps-services"
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  nobridge       bridge container(s) running in track-binocle: mail-bridge"
  setup_apps
  printf '443 3102\n8443 4200\n' >"$T/funnel-apps"
  run_pf verify apps
  has "FAIL  nobridge       a Funnel node proxies to a bridge port: 8443 / 127.0.0.1:4200"
}

@test "nobridge FAILs when a node that must be read does not answer, and names it" {
  rm "$T/apps-node"
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  nobridge       cannot read the Funnel targets of: apps"
  setup_apps
  TS_DOWN=1 run_pf verify --pre
  has "FAIL  nobridge       cannot read the Funnel targets of: main"
}

@test "nobridge does not require the apps node when no origin is set and it has no state, and says so" {
  rm "$T/apps-node"
  set_env PUBLIC_MAIL_ORIGIN ""
  set_env PUBLIC_CALENDAR_ORIGIN ""
  run_pf verify --pre
  has "PASS  nobridge"
  has "apps node not deployed: not checked"
  mkdir -p "$T/state/tailscale-osionos-apps"
  run_pf verify --pre
  has "FAIL  nobridge       cannot read the Funnel targets of: apps"
}

@test "nodev passes on 10 probes of 404 and FAILs naming the leaking app and path" {
  run_pf verify --pre
  has "PASS  nodev          10 probes"
  NODEV_LEAK=/@vite/client run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  nodev          not 404: mail/@vite/client=200 calendar/@vite/client=200"
  NODEV_CODE=200 run_pf verify --pre
  has "mail/package.json=200"
}

@test "apphdrs passes on the page and on a 404, and FAILs on each missing or forbidden header" {
  run_pf verify --pre
  has "PASS  apphdrs"
  sed -i "s/script-src 'self'/script-src 'self' 'unsafe-inline'/" "$T/hdr-3102"
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "mail/: csp:'script-src 'self''"
  setup_apps
  sed -i 's/frame-ancestors [^\r]*/frame-ancestors */' "$T/hdr-3103"
  run_pf verify --pre
  has "calendar/: csp:'frame-ancestors https://osionos.tail10f2ea.ts.net:8443'"
  setup_apps
  sed -i '/nosniff/d; /referrer-policy/d; /strict-transport/d' "$T/hdr-3102"
  run_pf verify --pre
  has "nosniff referrer-policy hsts"
  setup_apps
  printf 'access-control-allow-origin: *\r\nx-frame-options: DENY\r\n' >>"$T/hdr-3103"
  run_pf verify --pre
  has "ACAO-present X-Frame-Options-present"
}

@test "apphdrs FAILs when an app answers nothing" {
  : >"$T/hdr-3102"
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "mail/:no answer;"
}

@test "bundle2 passes on clean images and FAILs naming the image and pattern, never a value" {
  run_pf verify --pre
  has "PASS  bundle2"
  MAIL_BUNDLE_HITS=2 run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  bundle2        found: osionos-mail-web:public:GOCSPX-(2)"
  has "osionos-mail-web:public:JWT_SECRET(2)"
  lacks "jwt-AAAA-1111"
  CAL_BUNDLE_HITS=1 run_pf verify --pre
  has "osionos-calendar-web:public:service_role(1)"
}

@test "bundle2 FAILs on an image with no files, and SKIPs a missing image when apps are not deployed" {
  FILES=0 run_pf verify --pre
  [ "$status" -eq 1 ]
  has "unscannable:track-binocle/osionos-mail-web:public"
  set_env PUBLIC_MAIL_ORIGIN ""
  set_env PUBLIC_CALENDAR_ORIGIN ""
  IMG_RC=1 run_pf verify --pre
  has "SKIP  bundle2"
}

@test "appurls passes when the osionos image holds both origins and no localhost" {
  run_pf verify --pre
  has "PASS  appurls        track-binocle/osionos-web:public contains https://osionos-apps.tail10f2ea.ts.net and https://osionos-apps.tail10f2ea.ts.net:8443, no localhost"
}

@test "appurls FAILs on a missing origin, a localhost link and an inconsistent pair" {
  MAIL_HITS=0 run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  appurls        track-binocle/osionos-web:public does not contain the origin: https://osionos-apps.tail10f2ea.ts.net(0)"
  CAL_HITS=0 run_pf verify --pre
  has "does not contain the origin: https://osionos-apps.tail10f2ea.ts.net:8443(0)"
  LINK_OUT=1 run_pf verify --pre
  has "FAIL  appurls        track-binocle/osionos-web:public has 1 file(s) linking to localhost"
  set_env PUBLIC_CALENDAR_ORIGIN ""
  run_pf verify --pre
  has "FAIL  appurls        only one of PUBLIC_MAIL_ORIGIN, PUBLIC_CALENDAR_ORIGIN is set"
  set_env PUBLIC_CALENDAR_ORIGIN https://osionos-apps.tail10f2ea.ts.net:9443
  run_pf verify --pre
  has "PUBLIC_CALENDAR_ORIGIN is not PUBLIC_MAIL_ORIGIN:8443"
}

@test "appurls FAILs when the apps share the main hostname, and SKIPs when both origins are unset" {
  set_env PUBLIC_MAIL_ORIGIN https://osionos.tail10f2ea.ts.net
  set_env PUBLIC_CALENDAR_ORIGIN https://osionos.tail10f2ea.ts.net:8443
  run_pf verify --pre
  has "FAIL  appurls        the apps origins share PUBLIC_ORIGIN host osionos.tail10f2ea.ts.net"
  set_env PUBLIC_MAIL_ORIGIN ""
  set_env PUBLIC_CALENDAR_ORIGIN ""
  run_pf verify --pre
  has "SKIP  appurls        origins unset"
}

@test "appenv passes on clean containers and FAILs naming the variable, never its value" {
  run_pf verify --pre
  has "PASS  appenv         mail-web and calendar-web hold 6 variables"
  echo "SMTP_PASS=hunter2-secret" >>"$T/env-mail"
  echo "JWT_SECRET=hunter3-secret" >>"$T/env-cal"
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  appenv         forbidden variable(s) present (values withheld): mail-web:SMTP_PASS calendar-web:JWT_SECRET"
  lacks "hunter"
}

@test "appenv FAILs when the environment cannot be read or comes back empty, instead of passing 0 variables" {
  ENV_FAIL=1 run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  appenv         environment unreadable or empty for: mail-web calendar-web"
  lacks "PASS  appenv"
  : >"$T/env-mail"
  run_pf verify --pre
  has "FAIL  appenv         environment unreadable or empty for: mail-web"
  lacks "for: mail-web calendar-web"
}

@test "tls2 prints exactly one line when the apps node has no open port: FAIL when apps are expected, SKIP when not" {
  : >"$T/funnel-apps"
  run_pf verify apps
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$out" | grep -c '^[A-Z]*  tls2')" -eq 1 ]
  has "FAIL  tls2"
  set_env PUBLIC_MAIL_ORIGIN ""
  set_env PUBLIC_CALENDAR_ORIGIN ""
  run_pf verify
  [ "$(printf '%s\n' "$out" | grep -c '^[A-Z]*  tls2')" -eq 1 ]
  has "SKIP  tls2"
}

@test "tls2 labels the apps node's certificate probes apart from the main node's tls" {
  run_pf verify apps
  has "PASS  tls2           https://osionos-apps.tail10f2ea.ts.net:443 serves a valid certificate"
  TLS_RC=35 run_pf verify apps
  has "FAIL  tls2"
  lacks "FAIL  tls  "
}

@test "appenv FAILs a missing container when apps are deployed and SKIPs it when they are not" {
  rm "$T/env-mail"
  run_pf verify --pre
  [ "$status" -eq 1 ]
  has "FAIL  appenv         mail-web is not running"
  set_env PUBLIC_MAIL_ORIGIN ""
  set_env PUBLIC_CALENDAR_ORIGIN ""
  run_pf verify --pre
  has "SKIP  appenv"
}
