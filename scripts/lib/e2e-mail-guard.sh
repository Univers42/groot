#!/bin/sh
# e2e-mail-guard.sh — may the e2e specs that send real mail (pr*, dm*) run on this machine?
#
#   e2e_names_mail_specs ARG...  Exit 0 when an argument names a pr*/dm* spec (its last path
#                                component starts with pr<digit> or dm<digit>), else 1.
#   e2e_mail_guard               Exit 0 when every mail those specs cause can reach only
#                                Mailpit and no test user can land on a remote backend. Else
#                                print one reason line on stdout and exit 1.
#
# It reads what RUNS (docker), never a config file that may not be applied, because the
# danger is a gateway or GoTrue started with the team's real relay (verdict B C11, C12):
#   1. the link relay does not point at a remote backend (link state mode ssh or direct, or
#      a running grobase-link relay with no state);
#   2. every auth-gateway container runs with PUBLIC_BAAS_URL = the local Kong (the gateway
#      holds no SMTP config: it mails through grobase, ADR 0006);
#   3. mini-baas-gotrue runs on this daemon with GOTRUE_SMTP_HOST = a Mailpit name;
#   4. mini-baas-orchestrator and mini-baas-tenant-control, the two grobase senders behind
#      /email/v1, run with SMTP_HOST = Mailpit, so a developer with TITAN_* set cannot mail
#      real people from a spec.
# Only the one URL or SMTP host line is read out of a container's environment, which also
# holds secrets; nothing else from it is printed.
# Used by tests/e2e/run.sh; tested alone in scripts/tests/e2e-mail-guard.bats.
#
# Caveat: "Mailpit" is a host name: mailpit, mini-baas-mailpit, localhost or 127.0.0.1
# (E2E_MAILPIT_HOSTS), and "the local Kong" is the host mini-baas-kong (E2E_KONG_HOSTS). A
# container planted under that alias that relays onward passes; the real Mailpit reached
# by IP address is refused (over-reporting, the safe direction).
# Caveat: an orchestrator or tenant-control that is not running sends nothing and passes; one
# that runs with SMTP_HOST unset is refused, since its default cannot be proven.
# Caveat: a state file left behind by a crashed `make link` refuses until `make link-down`.

E2E_MAILPIT_HOSTS="${E2E_MAILPIT_HOSTS:-mailpit mini-baas-mailpit localhost 127.0.0.1}"
E2E_KONG_HOSTS="${E2E_KONG_HOSTS:-mini-baas-kong}"
E2E_MAIL_SENDERS="${E2E_MAIL_SENDERS:-mini-baas-orchestrator mini-baas-tenant-control}"

e2e_names_mail_specs() {
	for _em_arg in "$@"; do
		case "$_em_arg" in -*) continue ;; esac
		case "${_em_arg##*/}" in pr[0-9]* | dm[0-9]*) return 0 ;; esac
	done
	return 1
}

# _em_is_mailpit HOST — exact match against the Mailpit names.
_em_is_mailpit() {
	for _em_name in $E2E_MAILPIT_HOSTS; do
		[ "$1" = "$_em_name" ] && return 0
	done
	return 1
}

# _em_container_var CONTAINER KEY — KEY's value in the container's environment (last wins,
# as for a duplicated -e); empty when unset.
_em_container_var() {
	docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null |
		sed -n "s/^$2=//p" | tail -1
}

_em_link_reason() {
	_em_state="${GROBASE_LINK_DIR:-${XDG_RUNTIME_DIR:-/tmp}/track-binocle-link}/state"
	_em_mode=""
	[ -f "$_em_state" ] && _em_mode="$(sed -n 's/^mode=//p' "$_em_state" | tail -1)"
	case "$_em_mode" in
	ssh | direct)
		printf 'the link relay points at a remote backend (%s %s): test users must not land there; make link-down first\n' \
			"$_em_mode" "$(sed -n 's/^target=//p' "$_em_state" | tail -1)"
		return 0
		;;
	esac
	if [ "$_em_mode" != local ] &&
		[ -n "$(docker ps --filter label=com.docker.compose.service=grobase-link --format '{{.Names}}' 2>/dev/null)" ]; then
		printf 'a grobase-link relay runs but %s records no link mode: its backend is unknown; make link-down first\n' "$_em_state"
		return 0
	fi
	return 1
}

# _em_url_host URL — the host of scheme://[user@]host[:port]/path, without credentials.
_em_url_host() {
	_em_rest="${1#*://}"
	_em_rest="${_em_rest%%/*}"
	_em_rest="${_em_rest##*@}"
	printf '%s' "${_em_rest%%:*}"
}

_em_is_local_kong() {
	for _em_name in $E2E_KONG_HOSTS; do
		[ "$1" = "$_em_name" ] && return 0
	done
	return 1
}

_em_gateway_reason() {
	_em_gateways="$(docker ps --filter label=com.docker.compose.service=auth-gateway --format '{{.Names}}' 2>/dev/null)"
	if [ -z "$_em_gateways" ]; then
		printf 'no auth-gateway container runs, so its PUBLIC_BAAS_URL cannot be proven to be the local Kong\n'
		return 0
	fi
	for _em_gw in $_em_gateways; do
		_em_url="$(_em_container_var "$_em_gw" PUBLIC_BAAS_URL)"
		_em_is_local_kong "$(_em_url_host "$_em_url")" && continue
		printf '%s mails through PUBLIC_BAAS_URL=%s, not the local Kong (%s)\n' "$_em_gw" "${_em_url:-<unset>}" "$E2E_KONG_HOSTS"
		return 0
	done
	return 1
}

# The grobase services that own an SMTP client behind Kong. A stopped one sends nothing.
_em_sender_reason() {
	for _em_sender in $E2E_MAIL_SENDERS; do
		[ -n "$(docker ps --filter "name=^${_em_sender}\$" --format '{{.Names}}' 2>/dev/null)" ] || continue
		_em_host="$(_em_container_var "$_em_sender" SMTP_HOST)"
		_em_is_mailpit "$_em_host" && continue
		printf '%s sends mail through SMTP_HOST=%s, not Mailpit (%s)\n' "$_em_sender" "${_em_host:-<unset>}" "$E2E_MAILPIT_HOSTS"
		return 0
	done
	return 1
}

_em_gotrue_reason() {
	if [ -z "$(docker ps --filter 'name=^mini-baas-gotrue$' --format '{{.Names}}' 2>/dev/null)" ]; then
		printf 'mini-baas-gotrue does not run on this daemon, so its GOTRUE_SMTP_HOST cannot be proven to be Mailpit\n'
		return 0
	fi
	_em_host="$(_em_container_var mini-baas-gotrue GOTRUE_SMTP_HOST)"
	_em_is_mailpit "$_em_host" && return 1
	printf 'mini-baas-gotrue sends mail through GOTRUE_SMTP_HOST=%s, not Mailpit (%s)\n' "${_em_host:-<unset>}" "$E2E_MAILPIT_HOSTS"
	return 0
}

e2e_mail_guard() {
	_em_link_reason && return 1
	_em_gateway_reason && return 1
	_em_gotrue_reason && return 1
	_em_sender_reason && return 1
	return 0
}
