# shellcheck shell=bash
# build-args.sh — does every build arg compose passes reach the image build? Docker drops a
# --build-arg its Dockerfile never declares with only a warning, and vite inlines what it was not
# given as empty: osionos 2e24e1e8 made an empty VITE_WHITEBOARD_APP_URL hide the whiteboard,
# and app.Dockerfile had no ARG for it, so every image built through compose shipped without one.
#
#   compose_build_args FILE...   print `service<TAB>dockerfile<TAB>arg` for every build arg the
#                                files pass, later files overriding earlier ones like
#                                `docker compose -f A -f B`; dockerfile is a path relative to
#                                the first file's directory (context + dockerfile, default
#                                `Dockerfile`).
#   dropped_build_args DOCKERFILE ARG...
#                                print each ARG no stage both declares (`ARG NAME`) and then uses:
#                                a later line of that stage naming `$NAME`/`${NAME}`, or any later
#                                RUN, whose environment Docker fills with the stage's ARGs (which
#                                is how `RUN npm run build` hands VITE_* to vite).
#
# Caveat: compose files are read by indentation (services at 2 spaces, build keys at 6, args at
#   8, the layout every groot compose file uses), not by a YAML parser: a list-form `args:`, a
#   flow mapping or an anchor-merged build block is not seen, so an arg can be MISSED (silent).
#   On the Dockerfile side, any later RUN counts as a use, so an ARG declared before a RUN that
#   never reads it passes (silent); a stage ending in the declaration is reported.

compose_build_args() {
	local first_dir
	first_dir=$(dirname "$1")
	awk -v base="$first_dir" '
		FNR == 1 { dir = FILENAME; sub(/\/[^\/]*$/, "", dir); if (dir == FILENAME) dir = "."
			in_services = 0; svc = ""; in_build = 0; in_args = 0 }
		/^services:/ { in_services = 1; next }
		/^[^ #]/ { in_services = 0; svc = ""; next }
		!in_services { next }
		/^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { svc = $1; sub(/:$/, "", svc); in_build = 0; in_args = 0; next }
		svc == "" { next }
		/^    build:/ {
			in_build = 1; in_args = 0
			v = $0; sub(/^    build:[[:space:]]*/, "", v)
			if (v != "") ctx[svc] = dir "/" v
			next }
		/^    [^ ]/ { in_build = 0; in_args = 0; next }
		!in_build { next }
		/^      context:/ { v = $2; ctx[svc] = dir "/" v; next }
		/^      dockerfile:/ { df[svc] = $2; next }
		/^      args:/ { in_args = 1; next }
		/^      [^ ]/ { in_args = 0; next }
		in_args && /^        [A-Za-z_][A-Za-z0-9_]*:/ {
			k = $1; sub(/:$/, "", k)
			if (!((svc, k) in seen)) { seen[svc, k] = 1; order[++n] = svc SUBSEP k }
		}
		END {
			for (i = 1; i <= n; i++) {
				split(order[i], p, SUBSEP)
				c = (p[1] in ctx) ? ctx[p[1]] : base
				printf "%s\t%s/%s\t%s\n", p[1], c, (p[1] in df) ? df[p[1]] : "Dockerfile", p[2]
			}
		}' "$@" | while IFS=$'\t' read -r svc dockerfile arg; do
		printf '%s\t%s\t%s\n' "$svc" "$(realpath -m --relative-to="$first_dir" "$dockerfile")" "$arg"
	done
}

dropped_build_args() {
	local dockerfile="$1" arg
	shift
	for arg in "$@"; do
		awk -v a="$arg" '
			$1 == "FROM" { staged = 1; declared = 0; next }
			staged && $1 == "ARG" { name = $2; sub(/=.*/, "", name); if (name == a) declared = 1; next }
			declared && ($1 == "RUN" || $0 ~ ("\\$\\{?" a "([^A-Za-z0-9_]|$)")) { used = 1 }
			END { exit !used }' "$dockerfile" || printf '%s\n' "$arg"
	done
}
