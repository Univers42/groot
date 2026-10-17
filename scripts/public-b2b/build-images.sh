#!/usr/bin/env bash
# build-images.sh — build the public site and auth-gateway images on THIS host from one
# opposite-osiris commit, ready for deploy.sh to ship (ADR 0013, PUB-6/PUB-7).
#   usage: build-images.sh <opposite-osiris-worktree>
# Tags: prismatica-public/site:<sha12> and prismatica-public/auth-gateway:<sha12>.
#
# Why here: the b2b VM has no docker0 bridge, so a default-network build fails there.
# Why `docker build` from a temp context: compose build reads the user's ./.env and breaks
# buildx bake; the context is `git archive` of the committed tree (so the tag names the
# content) placed under apps/opposite-osiris/, the layout the Dockerfiles COPY from.
#
# Inputs from the human, never fetched here: a file (default ./.env.public-b2b, git-ignored)
# with PUBLIC_BAAS_ANON_KEY (b2b's anon key) and PUBLIC_TURNSTILE_SITE_KEY. Both are public
# values baked into the browser bundle. The site bakes these build args (Dockerfile ARGs):
# PUBLIC_BAAS_URL=/api and PUBLIC_AUTH_GATEWAY_URL=/api/auth (kept relative on purpose),
# PUBLIC_BAAS_ANON_KEY, PUBLIC_SITE_URL, PUBLIC_OSIONOS_APP_URL,
# PUBLIC_AUTH_REQUIRE_EMAIL_VERIFICATION, PUBLIC_TURNSTILE_SITE_KEY.
#
# Caveat: the PUB-7 check greps the built files; a URL assembled at runtime from parts would
# not match, and a hit does not prove the page uses it. The worktree must be clean:
# uncommitted changes are not built.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=lib.sh
. "$root/scripts/public-b2b/lib.sh"
# shellcheck source=../lib/envfile.sh
. "$root/scripts/lib/envfile.sh"

[ $# -eq 1 ] || fail "usage: build-images.sh <opposite-osiris-worktree>"
oo=$(cd "$1" && pwd)
build_env=${PUBLIC_BUILD_ENV_FILE:-$root/.env.public-b2b}

git -C "$oo" rev-parse --verify -q HEAD >/dev/null || fail "$oo is not a git worktree"
[ -f "$oo/docker/services/web/Dockerfile" ] || fail "$oo is not an opposite-osiris tree"
[ -z "$(git -C "$oo" status --porcelain)" ] || fail "$oo has uncommitted changes: commit them, the tag names a commit"
sha=$(git -C "$oo" rev-parse --short=12 HEAD)

anon_key=$(get_env "$build_env" PUBLIC_BAAS_ANON_KEY) || fail "PUBLIC_BAAS_ANON_KEY missing in $build_env"
site_key=$(get_env "$build_env" PUBLIC_TURNSTILE_SITE_KEY) || fail "PUBLIC_TURNSTILE_SITE_KEY missing in $build_env"

site_image=prismatica-public/site:$sha
gateway_image=prismatica-public/auth-gateway:$sha
context=$(mktemp -d)
trap 'rm -rf "$context"' EXIT

echo "== context: opposite-osiris $sha"
mkdir -p "$context/apps"
git -C "$oo" archive --prefix=apps/opposite-osiris/ HEAD | tar -x -C "$context"

echo "== build $site_image"
(
	cd "$context"
	docker build --platform linux/amd64 \
		-f apps/opposite-osiris/docker/services/web/Dockerfile \
		--build-arg "PUBLIC_BAAS_ANON_KEY=$anon_key" \
		--build-arg "PUBLIC_SITE_URL=$PUBLIC_URL" \
		--build-arg "PUBLIC_OSIONOS_APP_URL=$PUBLIC_URL" \
		--build-arg "PUBLIC_AUTH_REQUIRE_EMAIL_VERIFICATION=true" \
		--build-arg "PUBLIC_TURNSTILE_SITE_KEY=$site_key" \
		-t "$site_image" .
)

echo "== build $gateway_image"
(
	cd "$context"
	docker build --platform linux/amd64 \
		-f apps/opposite-osiris/docker/services/api-gateway/Dockerfile \
		-t "$gateway_image" .
)

echo "== PUB-7: the bundle names the Funnel URL and no localhost"
# The site URL is inlined into the HTML (canonical, og:*, sitemap), not into the JS chunks, which
# hold the anon key and relative /api paths. A baked default would read https://localhost:4322;
# the bare http://localhost:4322 in the JS is a hard-coded redirect allowlist entry
# (portal.ts isTrustedOsionosRedirect). Measured on b62ea8e21dd1, 2026-10-17.
count_in() { docker run --rm --entrypoint sh "$site_image" -c "find /usr/share/nginx/html -name '$2' -exec grep -lF '$1' {} + | wc -l"; }
html_funnel=$(count_in "$PUBLIC_HOST:$FUNNEL_PORT" '*.html')
js_localhost=$(count_in "https://localhost:4322" '*.js')
index_localhost=$(docker run --rm --entrypoint sh "$site_image" -c "grep -cF 'https://localhost:4322' /usr/share/nginx/html/index.html || true")
js_anon=$(count_in "$anon_key" '*.js')
echo "  html files with $PUBLIC_HOST:$FUNNEL_PORT: $html_funnel (want >= 1)"
echo "  js files with https://localhost:4322: $js_localhost (want 0); index.html with it: $index_localhost (want 0)"
echo "  js files with the anon key: $js_anon (want >= 1)"
[ "$html_funnel" -ge 1 ] || fail "no page contains $PUBLIC_HOST:$FUNNEL_PORT"
if [ "$js_localhost" -ne 0 ] || [ "$index_localhost" -ne 0 ]; then fail "the bundle still contains https://localhost:4322"; fi
[ "$js_anon" -ge 1 ] || fail "the anon key is not in the bundle"
echo "  info: js files with the literal http://localhost:4322 (portal.ts redirect allowlist, hard-coded): $(count_in "http://localhost:4322" '*.js')"
echo "  info: files that still name localhost:4322 (robots.txt Sitemap line, docs pages): $(count_in "localhost:4322" '*')"

echo "== images"
echo "  $site_image layers=$(layers_hash "$site_image")"
echo "  $gateway_image layers=$(layers_hash "$gateway_image")"
echo "next: bash scripts/public-b2b/deploy.sh $sha"
