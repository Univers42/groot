# shellcheck shell=bash
# mjs-closure.sh — which local .mjs modules does an entry point load? The bridge image copies only
# what its Dockerfile names, so a module the entry reaches but the image lacks crash-loops the
# container on ERR_MODULE_NOT_FOUND (groot main, CI run 39089475219).
#
#   mjs_closure DIR ENTRY    print, sorted, ENTRY and every module under DIR it reaches through
#                            relative `import … from './x.mjs'`, `export … from './x.mjs'` and
#                            `import('./x.mjs')`; a reached module absent from DIR is printed too.
#
# Caveat: a regex, not a parser. An import path built at runtime, one split across lines, or one
#   outside DIR (`../x.mjs`) is not followed, so the closure can come out SMALLER than Node's;
#   an import inside a comment or a string is followed, so it can also come out larger (noisy).

mjs_closure() {
	local dir="$1" f dep
	local -a queue=("$2")
	local -A seen=()
	while [ "${#queue[@]}" -gt 0 ]; do
		f="${queue[0]}"
		queue=("${queue[@]:1}")
		[ -n "${seen[$f]:-}" ] && continue
		seen[$f]=1
		[ -f "$dir/$f" ] || continue
		while IFS= read -r dep; do
			queue+=("$dep")
		done < <(grep -oE "(from|import)[[:space:]]*\(?[[:space:]]*['\"]\./[^'\"]+\.mjs['\"]" "$dir/$f" |
			grep -oE "\./[^'\"]+\.mjs" | sed 's#^\./##')
	done
	printf '%s\n' "${!seen[@]}" | LC_ALL=C sort
}
