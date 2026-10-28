#!/usr/bin/env bash
# deploy.sh — put the public Prismatica site on b2b behind Tailscale Funnel :10000
# (ADR 0013, devil PUB-1..16). Human-run, from the groot checkout, after build-images.sh and
# env-init.sh:   bash scripts/public-b2b/deploy.sh <oo-sha12>
#
# Order: preflight (reads only) -> ship images by explicit tag -> copy the compose file ->
# `up -d` in project prismatica-public -> loopback checks -> `tailscale funnel --https=10000`
# -> post-checks through the public URL. Any failure after the first write prints the
# rollback line. It never runs `tailscale serve reset` (that would erase the :443 hosts) and
# never touches mini-baas-* containers: the post-checks prove it (PUB-10).
#
# `tailscale funnel` runs without sudo here because the VM's operator is the ssh user
# (`tailscale debug prefs` shows OperatorUser, 2026-10-17). env-init.sh is the only step that
# needs sudo (it creates /opt/prismatica-public) and a terminal.
#
# Caveat: the PUB-3 probe tests the anon key on Kong at 127.0.0.1:8000 and demands 401/403,
# so a 200 with an empty list also stops the deploy: it cannot tell "no rows" from "column
# readable". The public-URL checks run from this host; a network that blocks :10000 (PUB-16)
# fails them although the funnel is up: set PUBLIC_CHECK_FROM=vm to run them from the VM.
# The tailscaled X-Forwarded-For behaviour (PUB-1) is not checked here; the phone test is.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib.sh
. "$root/scripts/public-b2b/lib.sh"

[[ $# -eq 1 ]] || fail "usage: deploy.sh <oo-sha12>   (the tag printed by build-images.sh)"
sha=$1
site_image=prismatica-public/site:$sha
gateway_image=prismatica-public/auth-gateway:$sha
redis_image=${PUBLIC_REDIS_IMAGE:-redis:7-alpine}
port=${PRISMATICA_PUBLIC_PORT:-10080}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
before_json=$REMOTE_DIR/serve-before-$stamp.json
after_json=$REMOTE_DIR/serve-after-$stamp.json
compose="docker compose -p $PROJECT --env-file $REMOTE_DIR/images.env -f $REMOTE_DIR/public-b2b.yml"
rollback="bash scripts/public-b2b/rollback.sh $before_json"
wrote_on_vm=0

on_exit() {
	local status=$?
	if [[ "$status" -ne 0 ]] && [[ "$wrote_on_vm" -eq 1 ]]; then
		echo "== FAILED (exit $status). Roll back with:" >&2
		echo "   $rollback" >&2
	fi
}
trap on_exit EXIT

# curl from this host, or from the VM when PUBLIC_CHECK_FROM=vm. Prints the status code only.
public_status() {
	local method=$1 path=$2
	if [[ "${PUBLIC_CHECK_FROM:-host}" = vm ]]; then
		"${B2B[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X $method -d '{}' -H 'content-type: application/json' '$PUBLIC_URL$path'"
	else
		curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X "$method" -d '{}' -H 'content-type: application/json' "$PUBLIC_URL$path" || true
	fi
}

expect_status() {
	local label=$1 got=$2 want
	shift 2
	for want in "$@"; do
		if [[ "$got" = "$want" ]]; then
			echo "  ok   $label -> $got"
			return 0
		fi
	done
	fail "$label -> $got, want $*"
}

echo "== 0. local images"
for image in "$site_image" "$gateway_image"; do
	docker image inspect "$image" >/dev/null 2>&1 || fail "$image is not built here: run build-images.sh"
done
site_layers=$(layers_hash "$site_image")
gateway_layers=$(layers_hash "$gateway_image")
echo "  $site_image layers=$site_layers"
echo "  $gateway_image layers=$gateway_layers"

echo "== 1. preflight on the VM (reads only)"
self=$("${B2B[@]}" "tailscale status --json | jq -r .Self.DNSName")
[[ "$self" = "$PUBLIC_HOST." ]] || fail "this node is $self, the URL and the build assume $PUBLIC_HOST."
"${B2B[@]}" "tailscale serve status --json | jq -e --arg h '$PUBLIC_HOST:$FUNNEL_PORT' '.Web[\$h] == null' >/dev/null" ||
	fail ":$FUNNEL_PORT is already configured in the serve config: inspect it, then rollback.sh or stop"
"${B2B[@]}" "test -d $REMOTE_DIR" || fail "$REMOTE_DIR is missing: run env-init.sh first"

echo "  PUB-3: anon cannot read users.email through Kong"
probe=$("${B2B[@]}" bash -s <<'PROBE'
anon=$(grep -E '^ANON_KEY=' /opt/grobase/.env | tail -1 | cut -d= -f2- | tr -d "\"'")
body=$(mktemp)
code=$(curl -s -o "$body" -w '%{http_code}' --max-time 10 \
	"http://127.0.0.1:8000/rest/v1/users?select=email&limit=1" \
	-H "apikey: $anon" -H "Authorization: Bearer $anon")
at_signs=$(grep -c '@' "$body" || true)
rm -f "$body"
echo "$code $at_signs"
PROBE
)
read -r probe_code probe_at <<<"$probe"
echo "  status=$probe_code at_sign_in_body=$([[ "$probe_at" = 0 ]] && echo no || echo YES)"
[[ "$probe_at" = 0 ]] || fail "PUB-3: an email came back for the anon key: fix the users grant, do not ship"
case $probe_code in
401 | 403) ;;
*) fail "PUB-3: anon got $probe_code on users?select=email, want a permission error (401/403)" ;;
esac

echo "  PUB-9: save the serve config; PUB-10: record the WAF and the mini-baas containers"
"${B2B[@]}" "tailscale serve status --json > $before_json && chmod 600 $before_json"
waf_before=$("${B2B[@]}" "docker inspect mini-baas-waf --format '{{.Id}} {{.State.StartedAt}}'")
ps_before=$("${B2B[@]}" "docker compose -p mini-baas ps -a -q | sort | sha256sum | cut -c1-16")
count_before=$("${B2B[@]}" "docker compose -p mini-baas ps -a -q | wc -l")
echo "  saved $before_json"
echo "  waf: ${waf_before:0:12} ...  mini-baas containers: $count_before digest $ps_before"

echo "  port $port is free (or ours)"
busy=$("${B2B[@]}" "ss -ltn 'sport = :$port' | grep -c LISTEN || true")
ours=$("${B2B[@]}" "docker ps -q --filter label=com.docker.compose.project=$PROJECT | wc -l")
{ [[ "$busy" = 0 ]] || [[ "$ours" -gt 0 ]]; } || fail "port $port is taken by something that is not $PROJECT"

echo "  $REMOTE_DIR/.env: mode 600, keys present (names only)"
"${B2B[@]}" bash -s <<ENVCHECK || fail "$REMOTE_DIR/.env is not ready: run env-init.sh"
set -u
f=$REMOTE_DIR/.env
[ "\$(stat -c %a "\$f")" = 600 ] || { echo "  mode is not 600"; exit 1; }
bad=0
for k in SERVICE_ROLE_KEY PUBLIC_BAAS_ANON_KEY AUTH_LINK_SIGNING_KEY TURNSTILE_SECRET_KEY AUTH_SIGNUP_ALLOWLIST; do
	if grep -q "^\$k=." "\$f"; then echo "  \$k set"; else echo "  \$k UNSET"; bad=1; fi
done
if grep -q '^AUTH_DEMO_INSECURE=' "\$f"; then echo "  AUTH_DEMO_INSECURE present (PUB-8)"; bad=1; fi
exit \$bad
ENVCHECK

echo "== 2. ship images by explicit tag (from here on the VM changes)"
wrote_on_vm=1
for pair in "$site_image|$site_layers" "$gateway_image|$gateway_layers"; do
	image=${pair%|*}
	want=${pair##*|}
	docker save "$image" | "${B2B[@]}" 'docker load -q' >/dev/null
	got=$(remote_layers_hash "$image")
	[[ "$got" = "$want" ]] || fail "layers of $image differ on b2b ($got vs $want)"
	echo "  $image layers=$got (match)"
done
if ! "${B2B[@]}" "docker image inspect $redis_image >/dev/null 2>&1"; then
	docker image inspect "$redis_image" >/dev/null 2>&1 || fail "$redis_image is on neither side: docker pull it here"
	docker save "$redis_image" | "${B2B[@]}" 'docker load -q' >/dev/null
	echo "  shipped $redis_image"
fi

echo "== 3. compose file and image tags"
"${B2B[@]}" "cat > $REMOTE_DIR/public-b2b.yml" <"$root/infrastructure/compose/public-b2b.yml"
printf 'PUBLIC_SITE_IMAGE=%s\nPUBLIC_GATEWAY_IMAGE=%s\nPUBLIC_REDIS_IMAGE=%s\nPRISMATICA_PUBLIC_PORT=%s\n' \
	"$site_image" "$gateway_image" "$redis_image" "$port" | "${B2B[@]}" "cat > $REMOTE_DIR/images.env"
local_sum=$(sha256sum <"$root/infrastructure/compose/public-b2b.yml" | cut -c1-16)
remote_sum=$("${B2B[@]}" "sha256sum < $REMOTE_DIR/public-b2b.yml | cut -c1-16")
[[ "$local_sum" = "$remote_sum" ]] || fail "compose file differs on the VM ($remote_sum vs $local_sum)"
echo "  public-b2b.yml $remote_sum (match)"

echo "== 4. up -d in project $PROJECT (no build, no pull)"
"${B2B[@]}" "$compose up -d --no-build --pull never 2>&1 | tail -8"
for service in public-redis public-auth-gateway public-site; do
	state=starting
	for _ in $(seq 1 40); do
		state=$("${B2B[@]}" "docker inspect -f '{{.State.Health.Status}}' \$($compose ps -q $service)" 2>/dev/null || echo starting)
		[[ "$state" = healthy ]] && break
		sleep 3
	done
	[[ "$state" = healthy ]] || fail "$service is $state after 2 minutes: ssh b2b '$compose logs $service'"
	echo "  $service healthy"
done
boot=$("${B2B[@]}" "$compose logs --no-log-prefix public-auth-gateway 2>&1 | grep -E 'FATAL|listening' | tail -3" || true)
printf '  gateway: %s\n' "${boot//$'\n'/$'\n'  gateway: }"
if grep -q FATAL <<<"$boot"; then fail "PUB-8: the gateway guards refused the configuration"; fi
grep -q 'trusted proxy hops: 2' <<<"$boot" || fail "PUB-1: the gateway does not report 2 trusted proxy hops"

echo "== 5. loopback checks before the funnel opens"
loopback_status() {
	"${B2B[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 10 $1 || true"
}
expect_status "GET /" "$(loopback_status "http://127.0.0.1:$port/")" 200
expect_status "GET /api/auth/health" "$(loopback_status "http://127.0.0.1:$port/api/auth/health")" 200
expect_status "POST /api/email/v1/send (anon, via the WAF)" \
	"$(loopback_status "-X POST -d '{}' http://127.0.0.1:$port/api/email/v1/send")" 401 403
expect_status "POST /api/v1/auth/otp/request (anon, via the WAF)" \
	"$(loopback_status "-X POST -d '{}' http://127.0.0.1:$port/api/v1/auth/otp/request")" 401 403

echo "== 6. open the funnel: only the :$FUNNEL_PORT keys may change"
"${B2B[@]}" "tailscale funnel --bg --https=$FUNNEL_PORT http://127.0.0.1:$port" 2>&1 | sed 's/^/  /'
"${B2B[@]}" "tailscale serve status --json > $after_json && chmod 600 $after_json"
serve_adds_only_funnel_keys "$before_json" "$after_json" ||
	fail "PUB-9: the serve config changed beyond the :$FUNNEL_PORT keys (compare $before_json and $after_json)"
echo "  ok   serve diff adds only TCP/Web/AllowFunnel :$FUNNEL_PORT; both :443 hosts equal"
waf_after=$("${B2B[@]}" "docker inspect mini-baas-waf --format '{{.Id}} {{.State.StartedAt}}'")
[[ "$waf_after" = "$waf_before" ]] || fail "PUB-10: mini-baas-waf changed ($waf_before -> $waf_after)"
ps_after=$("${B2B[@]}" "docker compose -p mini-baas ps -a -q | sort | sha256sum | cut -c1-16")
[[ "$ps_after" = "$ps_before" ]] || fail "PUB-5: the mini-baas container set changed ($ps_before -> $ps_after)"
echo "  ok   WAF Id+StartedAt unchanged; mini-baas digest $ps_after unchanged"

echo "== 7. through $PUBLIC_URL (certificate issuance can take a minute)"
status=000
for _ in $(seq 1 12); do
	status=$(public_status GET /)
	[[ "$status" = 200 ]] && break
	sleep 5
done
expect_status "GET /" "$status" 200
expect_status "GET /api/auth/health" "$(public_status GET /api/auth/health)" 200
expect_status "POST /api/email/v1/send" "$(public_status POST /api/email/v1/send)" 401 403
expect_status "POST /api/v1/auth/otp/request" "$(public_status POST /api/v1/auth/otp/request)" 401 403
if [[ "${PUBLIC_CHECK_FROM:-host}" = vm ]]; then
	page=$("${B2B[@]}" "curl -s --max-time 15 '$PUBLIC_URL/'")
else
	page=$(curl -s --max-time 15 "$PUBLIC_URL/")
fi
grep -qF "$PUBLIC_HOST:$FUNNEL_PORT" <<<"$page" || fail "PUB-7: the served page does not name $PUBLIC_HOST:$FUNNEL_PORT"
if grep -qF "https://localhost:4322" <<<"$page"; then fail "PUB-7: the served page names https://localhost:4322"; fi
echo "  ok   served page names $PUBLIC_HOST:$FUNNEL_PORT and not https://localhost:4322"

echo "== PASS: $PUBLIC_URL is live. Not done until the PUB-12 phone run (wiki/runbooks/public-site-b2b.md)."
echo "   rollback: $rollback"
