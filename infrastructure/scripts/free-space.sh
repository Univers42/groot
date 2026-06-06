#!/usr/bin/env bash
# ============================================================================
# free-space.sh — interactive, SAFE disk reclaimer for a dev machine.
#
# Scans the usual space hogs (Docker cache/images/volumes, package-manager
# caches, trash, Rust target/ and node_modules build dirs) under $HOME, shows
# how much each can free and how risky it is, and removes ONLY what you select
# and confirm. Nothing is ever deleted automatically.
#
#   ./free-space.sh          interactive menu
#   ./free-space.sh --scan   report only (no prompts, deletes nothing)
#   ./free-space.sh --safe   auto-select the no-data-loss groups (still confirms)
#
# Selection: space-separated numbers ("1 4 5"), "safe", "all", or "q".
# Risk legend:  [safe] regenerated/cache   [build] rebuild/reinstall needed
#               [DATA] may delete real data — listed per item before removal
# ============================================================================
set -u

MODE="${1:-menu}"
HOME_DIR="${HOME:?HOME not set}"
have() { command -v "$1" >/dev/null 2>&1; }
hsize() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }            # human size of a path
bytes() { du -sb "$1" 2>/dev/null | awk '{print $1+0}'; }         # bytes (for "is it worth it")

c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_dim=$'\033[2m'
c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_cyn=$'\033[36m'

# Category registry (parallel arrays). kind: dockercmd | paths | find-target | find-nodemods | volumes
LABEL=();  RISK=();  KIND=();  PAYLOAD=()
add() { LABEL+=("$1"); RISK+=("$2"); KIND+=("$3"); PAYLOAD+=("$4"); }

add "Docker build cache"                 safe  dockercmd "builder prune -af"
add "Docker dangling (untagged) images"  safe  dockercmd "image prune -f"
add "Docker stopped containers"          safe  dockercmd "container prune -f"
add "Docker unused networks"             safe  dockercmd "network prune -f"
add "~/.cache (browser, thumbnails, …)"  safe  paths     "$HOME_DIR/.cache"
add "Package caches (npm/pnpm/cargo/pip/go)" safe paths \
    "$HOME_DIR/.npm/_cacache $HOME_DIR/.cache/pnpm $HOME_DIR/.local/share/pnpm/store $HOME_DIR/.cargo/registry/cache $HOME_DIR/.cargo/registry/src $HOME_DIR/.cache/pip $HOME_DIR/.cache/go-build $HOME_DIR/.cache/yarn"
add "Trash"                              safe  paths     "$HOME_DIR/.local/share/Trash"
add "Rust target/ build dirs (under \$HOME)" build find-target  "$HOME_DIR"
add "node_modules dirs (under \$HOME)"   build find-nodemods "$HOME_DIR"
add "Docker UNUSED images (tagged, re-pull/rebuild)" build dockercmd "image prune -af"
add "Docker UNUSED volumes"              DATA  volumes   ""

risk_color() { case "$1" in safe) printf '%s' "$c_grn";; build) printf '%s' "$c_yel";; DATA) printf '%s' "$c_red";; esac; }

# ---- size probes -----------------------------------------------------------
docker_df() { have docker && docker system df 2>/dev/null; }
paths_size() { local total=0 p; for p in $1; do [ -e "$p" ] && total=$((total + $(bytes "$p"))); done; numfmt --to=iec "$total" 2>/dev/null || echo "$total"; }
find_target_list() { find "$1" -type d -name target -prune 2>/dev/null | while read -r d; do [ -f "$(dirname "$d")/Cargo.toml" ] && echo "$d"; done; }
find_nodemods_list() { find "$1" -type d -name node_modules -prune 2>/dev/null; }
volumes_list() { have docker && docker volume ls -qf dangling=true 2>/dev/null; }

category_size() {
  local i="$1"
  case "${KIND[$i]}" in
    dockercmd) echo "(see Docker summary)";;
    paths)     paths_size "${PAYLOAD[$i]}";;
    find-target)   local t=0 d; while read -r d; do [ -n "$d" ] && t=$((t+$(bytes "$d"))); done < <(find_target_list "${PAYLOAD[$i]}"); numfmt --to=iec "$t" 2>/dev/null;;
    find-nodemods) local t=0 d; while read -r d; do [ -n "$d" ] && t=$((t+$(bytes "$d"))); done < <(find_nodemods_list "${PAYLOAD[$i]}"); numfmt --to=iec "$t" 2>/dev/null;;
    volumes)   echo "$(volumes_list | wc -l) vol(s) (see Docker summary)";;
  esac
}

print_header() {
  echo "${c_bold}${c_cyn}Track Binocle — disk reclaimer${c_reset}"
  df -h "$HOME_DIR" | awk 'NR==1||/[0-9]%/{printf "  %s\n",$0}'
  if have docker; then echo "${c_dim}  Docker:${c_reset}"; docker_df | sed 's/^/    /'; fi
  echo
}

print_menu() {
  printf "  ${c_bold}%-3s %-44s %-12s %s${c_reset}\n" "#" "Category" "Reclaimable" "Risk"
  local i
  for i in "${!LABEL[@]}"; do
    printf "  %-3s %-44s %-12s %s%s%s\n" "$((i+1))" "${LABEL[$i]}" "$(category_size "$i")" "$(risk_color "${RISK[$i]}")" "[${RISK[$i]}]" "$c_reset"
  done
  echo
  echo "  Select: numbers (e.g. ${c_bold}1 5 6${c_reset}), ${c_bold}safe${c_reset} (all [safe]), ${c_bold}all${c_reset}, or ${c_bold}q${c_reset} to quit."
}

confirm() { printf "%s [y/N] " "$1"; read -r a; [ "$a" = y ] || [ "$a" = Y ]; }

run_category() {
  local i="$1"
  case "${KIND[$i]}" in
    dockercmd)
      echo "  -> docker ${PAYLOAD[$i]}"
      confirm "  Remove '${LABEL[$i]}'?" && docker ${PAYLOAD[$i]} ;;
    paths)
      echo "  Will clear contents of: ${PAYLOAD[$i]}"
      confirm "  Clear '${LABEL[$i]}' ($(paths_size "${PAYLOAD[$i]}"))?" || return
      local p; for p in ${PAYLOAD[$i]}; do
        case "$p" in "$HOME_DIR"/*) [ -e "$p" ] && rm -rf "${p:?}/"* 2>/dev/null && echo "    cleared $p";; esac
      done ;;
    find-target|find-nodemods)
      local lister; [ "${KIND[$i]}" = find-target ] && lister=find_target_list || lister=find_nodemods_list
      local dirs; mapfile -t dirs < <($lister "${PAYLOAD[$i]}")
      [ "${#dirs[@]}" -eq 0 ] && { echo "  none found."; return; }
      echo "  Found ${#dirs[@]} dir(s):"; local k; for k in "${!dirs[@]}"; do printf "    %-3s %-8s %s\n" "$((k+1))" "$(hsize "${dirs[$k]}")" "${dirs[$k]}"; done
      printf "  Delete which? numbers, 'all', or blank to skip: "; read -r sel
      [ -z "$sel" ] && return
      local targets=()
      if [ "$sel" = all ]; then targets=("${dirs[@]}"); else for n in $sel; do targets+=("${dirs[$((n-1))]}"); done; fi
      local t; for t in "${targets[@]}"; do case "$t" in "$HOME_DIR"/*) confirm "    rm -rf $t ?" && rm -rf "${t:?}" && echo "    removed";; esac; done ;;
    volumes)
      local vols; mapfile -t vols < <(volumes_list)
      [ "${#vols[@]}" -eq 0 ] && { echo "  no dangling volumes."; return; }
      echo "  ${c_red}DATA WARNING:${c_reset} these volumes are not attached to any container, but may hold real data."
      local k; for k in "${!vols[@]}"; do printf "    %-3s %s\n" "$((k+1))" "${vols[$k]}"; done
      printf "  Delete which? numbers, 'all', or blank to skip: "; read -r sel
      [ -z "$sel" ] && return
      local picks=()
      if [ "$sel" = all ]; then picks=("${vols[@]}"); else for n in $sel; do picks+=("${vols[$((n-1))]}"); done; fi
      local v; for v in "${picks[@]}"; do confirm "    docker volume rm $v ?" && docker volume rm "$v"; done ;;
  esac
}

# ---- modes -----------------------------------------------------------------
print_header
if [ "$MODE" = "--scan" ]; then print_menu; echo; echo "${c_dim}(scan only — nothing deleted)${c_reset}"; exit 0; fi

while :; do
  print_menu
  printf "> "; read -r choice
  case "$choice" in
    q|Q|"") echo "bye."; break;;
    all)  for i in "${!LABEL[@]}"; do echo; echo "${c_bold}${LABEL[$i]}${c_reset}"; run_category "$i"; done;;
    safe) for i in "${!LABEL[@]}"; do [ "${RISK[$i]}" = safe ] && { echo; echo "${c_bold}${LABEL[$i]}${c_reset}"; run_category "$i"; }; done;;
    *)    for n in $choice; do
            case "$n" in (*[!0-9]*) echo "  skip '$n'"; continue;; esac
            i=$((n-1)); [ "$i" -ge 0 ] && [ "$i" -lt "${#LABEL[@]}" ] && { echo; echo "${c_bold}${LABEL[$i]}${c_reset}"; run_category "$i"; } || echo "  no #$n";
          done;;
  esac
  echo; df -h "$HOME_DIR" | awk '/[0-9]%/{printf "  now: %s free on %s\n",$4,$6}'; echo
done
