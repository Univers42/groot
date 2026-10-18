#!/usr/bin/env bats
# make-help.awk unit tests run on fixture makefiles; the "repo contract" tests
# run on the real tree and fail until every utils/mk module carries ## markers.

AWK=utils/scripts/make-help.awk

setup() {
	cd "$BATS_TEST_DIRNAME/../.."
	A="$BATS_TEST_TMPDIR/a.mk"
	B="$BATS_TEST_TMPDIR/b.mk"
}

list() { awk -v mode=list "$@" -f "$AWK" "$A" ${B_FILE:+"$B"}; }
target() { awk -v mode=target -v target="$1" -f "$AWK" "$A"; }

@test "inline summary is listed under its section" {
	printf '##@ Apps\nbuild: ## Build the apps\n\t@true\n' >"$A"
	run list
	[ "$status" -eq 0 ]
	[[ "$output" == *$'Apps\n  build  Build the apps'* ]]
}

@test "prerequisites show in target mode, not in list mode" {
	printf '##@ Apps\nbuild: dep other ## Build\n\t@true\n' >"$A"
	run list
	[[ "$output" != *"Runs first"* && "$output" != *"dep other"* ]]
	run target build
	[ "$status" -eq 0 ]
	[[ "$output" == *"Runs first: dep other"* ]]
	[[ "$output" == *"make build"* ]]
}

@test "extended lines appear only in target mode" {
	printf '##@ Apps\nbuild: ## Build\n## Usage: make build X=<v>\n## second line\n\t@true\n' >"$A"
	run list
	[[ "$output" != *"Usage: make build"* ]]
	run target build
	[[ "$output" == *$'Usage: make build X=<v>\nsecond line'* ]]
}

@test "extended lines stop at a recipe, blank or plain comment" {
	printf '##@ A\nt: ## S\n\t@true\n## not mine\n# plain\n## nor me\n' >"$A"
	run target t
	[[ "$output" != *"not mine"* && "$output" != *"nor me"* ]]
}

@test "variable lines carrying ## never match" {
	printf '##@ A\nX := a ## b\nY ?= a ## b\nZ = a:b ## c\nW ::= a ## d\nreal: ## ok\n' >"$A"
	run list
	[[ "$output" == *"real"* ]]
	[[ "$output" != *"  X "* && "$output" != *"  Y "* && "$output" != *"  Z "* && "$output" != *"  W "* ]]
}

@test "double-colon rule is a target" {
	printf '##@ A\ndc:: ## Double\n' >"$A"
	run list
	[[ "$output" == *"dc  Double"* ]]
}

@test "multi-target line is not read (documented caveat)" {
	printf '##@ A\na b: ## x\n' >"$A"
	run list
	[[ "$output" != *"Double"* && "$output" != *"  a "* ]]
}

@test "the same section in two files merges" {
	printf '##@ Apps\none: ## 1\n' >"$A"
	printf '##@ Apps\ntwo: ## 2\n' >"$B"
	B_FILE=1 run list
	[ "$(grep -c '^Apps' <<<"$output")" -eq 1 ]
	[[ "$output" == *"one"* && "$output" == *"two"* ]]
}

@test "order variable goes first and unknown sections follow" {
	printf '##@ Zeta\nz: ## z\n##@ Beta\nb: ## b\n##@ Alpha\na: ## a\n' >"$A"
	run list -v 'order=Alpha|Beta|Missing'
	[ "$status" -eq 0 ]
	pos() { grep -n "^$1\$" <<<"$output" | cut -d: -f1; }
	[ "$(pos Alpha)" -lt "$(pos Beta)" ]
	[ "$(pos Beta)" -lt "$(pos Zeta)" ]
	[[ "$output" != *"Missing"* ]]
}

@test "a file without ##@ lands in Other and resets per file" {
	printf '##@ Apps\none: ## 1\n' >"$A"
	printf 'two: ## 2\n' >"$B"
	B_FILE=1 run list
	[[ "$output" == *$'Other\n  two'* ]]
}

@test "pattern rule is displayed with <target>" {
	printf '##@ A\nhelp-%%: ## Pattern\n' >"$A"
	run list
	[[ "$output" == *"help-<target>"* ]]
	run target 'help-%'
	[ "$status" -eq 0 ]
	[[ "$output" == *"make help-<target>"* ]]
}

@test "phony mode lists names once and excludes %" {
	printf '##@ A\na: ## x\nb%%: ## y\na:: ## again\n' >"$A"
	run awk -v mode=phony -f "$AWK" "$A"
	[ "$output" = "a" ]
}

@test "unknown target exits 1 with the message on stderr" {
	printf '##@ A\na: ## x\n' >"$A"
	run target nope
	[ "$status" -eq 1 ]
	[[ "$output" == *"no documented target 'nope' — make help lists them"* ]]
}

@test "undocumented target is unknown too" {
	printf '##@ A\nplain:\n\t@true\n' >"$A"
	run target plain
	[ "$status" -eq 1 ]
}

@test "no ESC byte without color=1, ESC with it" {
	printf '##@ A\na: ## x\n' >"$A"
	run list
	[[ "$output" != *$'\e'* ]]
	run list -v color=1
	[[ "$output" == *$'\e'* ]]
}

@test "names longer than the cap keep a gap and do not break rows" {
	long=$(printf 'n%.0s' $(seq 40))
	printf '##@ A\n%s: ## long\nshort: ## s\n' "$long" >"$A"
	run list
	[[ "$output" == *"$long  long"* ]]
}

# ---- repo contract: real tree ------------------------------------------------

phony_names() { awk -v mode=phony -f "$AWK" $(ls utils/mk/*.mk); }

@test "repo: every target line in utils/mk has an inline ## summary" {
	offenders=$(awk '
		FNR==1 {extended=0}
		/^[A-Za-z0-9][A-Za-z0-9_.%\/-]*[ \t]*::?([^=]|$)/ && !/##( |$)/ && !/^[A-Za-z0-9_.-]+[ \t]*[:?+]?=/ {
			printf "%s:%d:%s\n", FILENAME, FNR, $0 }' utils/mk/*.mk)
	[ -z "$offenders" ] || { echo "$offenders"; false; }
}

@test "repo: every summary is at most 80 characters" {
	long=$(for f in utils/mk/*.mk; do
		awk -v F="$f" '/^[A-Za-z0-9][A-Za-z0-9_.%\/-]*[ \t]*::?([^=]|$)/ && match($0,/## /) {
			s=substr($0,RSTART+3); if (length(s)>80) printf "%s:%d (%d)\n",F,FNR,length(s) }' "$f"
	done)
	[ -z "$long" ] || { echo "$long"; false; }
}

@test "repo: no target lands in Other" {
	run make -s help
	[ "$status" -eq 0 ]
	[[ "$output" != *$'\nOther\n'* ]]
}

@test "repo: make help lists exactly the phony set plus pattern targets" {
	listed=$(make -s help | awk '/^  [^ ]/ {print $1}' | grep -v '<target>' | sort -u)
	phony=$(phony_names | sort -u)
	[ "$listed" = "$phony" ] || { diff <(echo "$listed") <(echo "$phony"); false; }
}

@test "repo: make -s help-help exits 0" {
	run make -s help-help
	[ "$status" -eq 0 ]
}

@test "repo: unknown help target fails (make reports a failed recipe as 2)" {
	run make -s help-no-such-target
	[ "$status" -eq 2 ]
	[[ "$output" == *"no documented target 'no-such-target'"* ]]
}

@test "repo: make help prints no ESC byte when not a terminal" {
	run make -s help
	[[ "$output" != *$'\e'* ]]
}

@test "repo: every documented target is in .PHONY" {
	db=$(make -pq __none__ 2>/dev/null | sed -n 's/^\.PHONY: //p' | tr ' ' '\n' | sort -u)
	missing=$(comm -23 <(phony_names | sort -u) <(echo "$db"))
	[ -z "$missing" ] || { echo "$missing"; false; }
}

@test "repo: playground is phony despite the ./playground directory" {
	run make -n -o healthcheck -o playground-preview playground
	[ "$status" -eq 0 ]
	[[ "$output" != *"is up to date"* ]]
	[[ "$output" == *"playground-simulation"* ]]
}

@test "repo: an ordinary make run prints nothing extra" {
	run make -s --eval 'p: ; @:' p
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
