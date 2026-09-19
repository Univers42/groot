#!/bin/sh
# envfile.sh — the ONE primitive for editing a KEY=VALUE env file in place.
#
#   put_env FILE KEY VALUE   Set KEY to VALUE. The first live (non-comment) KEY= line is
#                            rewritten where it stands, later duplicates are dropped, a
#                            missing key is appended. Every other byte is preserved. The
#                            write is atomic (temp file beside FILE, then rename) and keeps
#                            FILE's mode (0600 for a file it creates). Never echoes VALUE.
#
# Sourced by scripts/gen-local-env.sh and scripts/ensure-live-data-access.sh — both edit
# ./.env.local, and two rewriters of the same secrets file drift apart (library-first).
# POSIX sh + awk + mktemp + stat only; tested alone in scripts/tests/envfile.bats.

# The rewrite itself: first live KEY= line replaced in place, later duplicates dropped,
# appended when absent. Key and value arrive via ENVIRON — no -v escape processing.
_PE_AWK=$(cat <<'AWK'
BEGIN { k = ENVIRON["ENVFILE_KEY"]; v = ENVIRON["ENVFILE_VAL"] }
{
	line = $0
	sub(/^[ \t]+/, "", line)
	eq = index(line, "=")
	if (line !~ /^#/ && eq > 1) {
		name = substr(line, 1, eq - 1)
		sub(/[ \t]+$/, "", name)
		if (name == k) { if (!seen) print k "=" v; seen = 1; next }
	}
	print
}
END { if (!seen) print k "=" v }
AWK
)

put_env() {
	_pe_file="$1"
	[ -f "$_pe_file" ] || (umask 077 && : >"$_pe_file")
	_pe_mode="$(stat -c %a "$_pe_file" 2>/dev/null || echo 600)"
	_pe_tmp="$(mktemp "$_pe_file.XXXXXX")" || return 1
	if ENVFILE_KEY="$2" ENVFILE_VAL="$3" awk "$_PE_AWK" "$_pe_file" >"$_pe_tmp" &&
		chmod "$_pe_mode" "$_pe_tmp" && mv -f "$_pe_tmp" "$_pe_file"; then
		return 0
	fi
	rm -f "$_pe_tmp"
	return 1
}
