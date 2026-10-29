# shellcheck shell=bash
# git-ignored.sh — would git pick a file up? A secret written into a checkout must not be one
# `git add -A` away from a commit (another session may run it in the same tree).
#
#   is_git_ignored PATH               true when the repository owning PATH ignores it — and when
#                                     there is no git or no repository to ask.
#   is_git_tracked PATH               true when the repository owning PATH tracks it; false with
#                                     no git or no repository to ask.
#   list_not_ignored ROOT [SUFFIX]    read paths relative to ROOT on stdin; print each one git
#                                     would take (a tracked file counts), or whose PATH+SUFFIX
#                                     (a backup name) it would take.
#
# Caveat: the owning repository is found from the nearest existing directory, so a path under a
# submodule that is not checked out yet is judged by the parent repository's rules.

git_owner_of() {
	local dir
	dir="$(dirname "$1")"
	while [ ! -d "$dir" ]; do dir="$(dirname "$dir")"; done
	git -C "$dir" rev-parse --show-toplevel 2>/dev/null
}

is_git_ignored() {
	local top
	command -v git >/dev/null || return 0
	top="$(git_owner_of "$1")" || return 0
	git -C "$top" check-ignore -q "$1"
}

is_git_tracked() {
	local top
	command -v git >/dev/null || return 1
	top="$(git_owner_of "$1")" || return 1
	git -C "$top" ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

list_not_ignored() {
	local root="$1" suffix="${2:-}" path
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		if ! is_git_ignored "$root/$path" || { [ -n "$suffix" ] && ! is_git_ignored "$root/$path$suffix"; }; then
			printf '%s\n' "$path"
		fi
	done
}
