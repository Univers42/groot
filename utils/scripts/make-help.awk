# make-help.awk - turns inline `##` markers in makefiles into help output.
#
#   awk -v mode=list   [-v order='A|B'] [-v color=1] -f make-help.awk Makefile ...
#   awk -v mode=target -v target=NAME   [-v color=1] -f make-help.awk Makefile ...
#   awk -v mode=phony                                -f make-help.awk Makefile ...
#
# Markers (see doc of the convention in utils/mk/help.mk):
#   ##@ Section title          starts a section; resets to "Other" at each file start
#   name: prereqs ## Summary   a documented target (`::` accepted)
#   ## free text               extended line, only directly under a target line or
#                              another extended line; shown by mode=target
#
# Sections merge by exact title across files. `order` (|-separated) prints first.
#
# Caveat: this is a line scanner, not make. It misses (under-reports) a target
# produced by $(eval), a multi-target line `a b: ## x` (only `a: ## x` form is
# read), and a target whose `##` sits on a continued (backslash) line. It
# mis-reads a target-specific variable `t: V := x ## y` as a target "t" with
# prerequisites "V := x". Escape hatch: write one `name: ## summary` per target.

function color_wrap(code, text) {
	if (!color) return text
	return sprintf("%c[%sm%s%c[0m", 27, code, text, 27)
}

function trim(text) {
	sub(/^[ \t]+/, "", text)
	sub(/[ \t]+$/, "", text)
	return text
}

function spaces(count,   out) {
	out = ""
	while (count-- > 0) out = out " "
	return out
}

function display_name(name) {
	gsub(/%/, "<target>", name)
	return name
}

# Sets parsed_name/parsed_summary/parsed_prereqs; returns 1 for a documented target line.
function parse_target(line,   rest, marker) {
	if (!match(line, /^[A-Za-z0-9][A-Za-z0-9_.%\/-]*/)) return 0
	parsed_name = substr(line, 1, RLENGTH)
	rest = substr(line, RLENGTH + 1)
	sub(/^[ \t]*/, "", rest)
	if (rest !~ /^::?/) return 0
	sub(/^::?/, "", rest)
	if (rest ~ /^=/) return 0
	if (!match(rest, /##( |$)/)) return 0
	marker = RSTART
	parsed_prereqs = trim(substr(rest, 1, marker - 1))
	parsed_summary = trim(substr(rest, marker + 2))
	return 1
}

function add_target(section,   index_of) {
	count++
	names[count] = parsed_name
	summaries[count] = parsed_summary
	prereqs[count] = parsed_prereqs
	sections[count] = section
	extended[count] = ""
	if (!(section in section_seen)) {
		section_seen[section] = 1
		section_titles[++section_count] = section
	}
	return count
}

function add_extended(line) {
	extended[last_target] = has_extended[last_target] ? extended[last_target] "\n" substr(line, 4) : substr(line, 4)
	has_extended[last_target] = 1
}

function print_section(title,   i, shown) {
	shown = 0
	for (i = 1; i <= count; i++) {
		if (sections[i] != title) continue
		if (!shown) printf "\n%s\n", color_wrap("1;33", title)
		shown = 1
		printf "  %s%s  %s\n", color_wrap("1;36", display_name(names[i])), \
			spaces(name_width - length(display_name(names[i]))), summaries[i]
	}
}

function compute_name_width(   i, len) {
	name_width = 0
	for (i = 1; i <= count; i++) {
		len = length(display_name(names[i]))
		if (len > name_width) name_width = len
	}
	if (name_width > 30) name_width = 30
}

function print_list(   ordered, ordered_count, i, is_ordered) {
	compute_name_width()
	printf "%s\n", "Usage: make <target> [VAR=value ...]"
	ordered_count = split(order, ordered, "|")
	for (i = 1; i <= ordered_count; i++) {
		if (ordered[i] in section_seen) print_section(ordered[i])
		is_ordered[ordered[i]] = 1
	}
	for (i = 1; i <= section_count; i++)
		if (!(section_titles[i] in is_ordered)) print_section(section_titles[i])
	printf "\nmake help-<target> prints one target's usage lines.\n"
}

function print_target(   i) {
	for (i = 1; i <= count; i++) {
		if (names[i] != target) continue
		printf "%s\n", color_wrap("1;36", "make " display_name(names[i]))
		printf "  %s\n", summaries[i]
		if (prereqs[i] != "") printf "Runs first: %s\n", prereqs[i]
		if (has_extended[i]) printf "\n%s\n", extended[i]
		return 1
	}
	printf "no documented target '%s' — make help lists them\n", target > "/dev/stderr"
	return 0
}

function print_phony(   i) {
	for (i = 1; i <= count; i++) {
		if (names[i] ~ /%/ || names[i] in phony_seen) continue
		phony_seen[names[i]] = 1
		print names[i]
	}
}

FNR == 1 { current_section = "Other"; last_target = 0 }

/^##@ / {
	current_section = trim(substr($0, 5))
	last_target = 0
	next
}

/^##( |$)/ {
	if (last_target) add_extended($0)
	next
}

{
	if (parse_target($0)) last_target = add_target(current_section)
	else last_target = 0
}

END {
	if (mode == "list") print_list()
	else if (mode == "phony") print_phony()
	else if (mode == "target") { if (!print_target()) exit 1 }
	else { print "make-help.awk: -v mode=list|target|phony required" > "/dev/stderr"; exit 2 }
}
