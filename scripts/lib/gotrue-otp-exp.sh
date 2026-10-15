#!/bin/sh
# gotrue-otp-exp.sh — GoTrue must not expire a confirmation token before the confirm link does.
#
#   gotrue_otp_exp_check GROBASE_DIR   Exit 0 when nothing sets GOTRUE_MAILER_OTP_EXP below
#                                      GOTRUE_OTP_EXP_FLOOR (86400 s, the confirm link's 24 h).
#                                      Else print one reason line on stdout and exit 1.
#
# The auth-gateway signs a 24 h link around a token GoTrue minted. If GoTrue's own expiry
# is shorter, the link verifies and the token is already dead (verdict B C14). Unset means
# GoTrue's default, 86400, which passes. Every place a value can come from is checked, so
# one that this edition does not load still fails:
#   1. a GOTRUE_MAILER_OTP_EXP entry in a grobase compose file (orchestrators/**/*.yml and
#      docker-compose*.yml), with ${NAME:-default} / ${NAME-default} / ${NAME} resolved
#      against GROBASE_DIR/.env (every value of NAME there is checked);
#   2. GROBASE_DIR/.env.gotrue, the optional env_file auth-api.yml gives GoTrue;
#   3. the running mini-baas-gotrue container's environment, when docker shows one.
# On baas, GROBASE_DIR is not on this machine: that check is human-run (Appendix A).
# Used by tests/e2e/run.sh; tested alone in scripts/tests/gotrue-otp-exp.bats.
#
# Caveat: compose files are read line by line. A value set through a YAML anchor, a
# multi-line scalar or a file outside GROBASE_DIR is not seen (under-reporting). A
# definition in an overlay this edition does not load still fails (over-reporting).

GOTRUE_OTP_EXP_FLOOR=86400

# _otp_judge VALUE SOURCE — the reason line when VALUE is not a whole number of seconds at
# or above the floor; nothing for an empty VALUE (unset = GoTrue's default).
_otp_judge() {
  [ -n "$1" ] || return 1
  case "$1" in
  *[!0-9]*)
    printf 'GOTRUE_MAILER_OTP_EXP=%s in %s is not a whole number of seconds\n' "$1" "$2"
    return 0
    ;;
  esac
  [ "$1" -ge "$GOTRUE_OTP_EXP_FLOOR" ] && return 1
  printf 'GOTRUE_MAILER_OTP_EXP=%s in %s is below %s s: GoTrue would expire the token before the 24 h confirm link\n' \
    "$1" "$2" "$GOTRUE_OTP_EXP_FLOOR"
  return 0
}

# _otp_env_values FILE KEY — every value of KEY in a KEY=VALUE file, quotes stripped.
_otp_env_values() {
  [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" |
    sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# _otp_compose_values GROBASE_DIR — "file<TAB>raw value" per compose definition, in both the
# map form (KEY: value, KEY: with no value = passthrough) and the list form (- KEY=value).
_otp_compose_values() {
  {
    find "$1/orchestrators" -name '*.yml' -type f 2>/dev/null
    for _otp_top in "$1"/docker-compose*.yml; do [ -f "$_otp_top" ] && printf '%s\n' "$_otp_top"; done
  } | sort | while IFS= read -r _otp_file; do
    sed -n \
      -e 's/^[[:space:]]*GOTRUE_MAILER_OTP_EXP:[[:space:]]*\(.*\)$/\1/p' \
      -e 's/^[[:space:]]*-[[:space:]]*["'\'']\{0,1\}GOTRUE_MAILER_OTP_EXP=\(.*\)$/\1/p' "$_otp_file" |
      sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/" |
      while IFS= read -r _otp_raw; do printf '%s\t%s\n' "$_otp_file" "$_otp_raw"; done
  done
}

# _otp_resolve RAW ENVFILE — the value(s) compose would substitute, one per line.
_otp_resolve() {
  case "$1" in
  '') _otp_env_values "$2" GOTRUE_MAILER_OTP_EXP ;;
  "\${"*"}")
    _otp_inner="${1#??}"
    _otp_inner="${_otp_inner%?}"
    case "$_otp_inner" in
    *:-*) _otp_name="${_otp_inner%%:-*}" _otp_default="${_otp_inner#*:-}" ;;
    *-*) _otp_name="${_otp_inner%%-*}" _otp_default="${_otp_inner#*-}" ;;
    *) _otp_name="$_otp_inner" _otp_default="" ;;
    esac
    _otp_set="$(_otp_env_values "$2" "$_otp_name")"
    if [ -n "$_otp_set" ]; then printf '%s\n' "$_otp_set"; else printf '%s\n' "$_otp_default"; fi
    ;;
  *) printf '%s\n' "$1" ;;
  esac
}

gotrue_otp_exp_check() {
  _otp_dir="$1"
  _otp_tab="$(printf '\t')"
  _otp_reason="$(
    _otp_compose_values "$_otp_dir" | while IFS="$_otp_tab" read -r _otp_file _otp_raw; do
      _otp_resolve "$_otp_raw" "$_otp_dir/.env" | while IFS= read -r _otp_value; do
        _otp_judge "$_otp_value" "${_otp_file#"$_otp_dir"/}" && exit 1
      done || exit 1
    done
  )"
  [ -z "$_otp_reason" ] || {
    printf '%s\n' "$_otp_reason" | head -1
    return 1
  }
  for _otp_value in $(_otp_env_values "$_otp_dir/.env.gotrue" GOTRUE_MAILER_OTP_EXP); do
    _otp_judge "$_otp_value" .env.gotrue && return 1
  done
  if command -v docker >/dev/null 2>&1 &&
    [ -n "$(docker ps --filter 'name=^mini-baas-gotrue$' --format '{{.Names}}' 2>/dev/null)" ]; then
    _otp_value="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' mini-baas-gotrue 2>/dev/null |
      sed -n 's/^GOTRUE_MAILER_OTP_EXP=//p' | tail -1)"
    _otp_judge "$_otp_value" "the running mini-baas-gotrue" && return 1
  fi
  return 0
}
