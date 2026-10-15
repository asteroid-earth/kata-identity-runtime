#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gravitational, Inc.
# Tests for render-config. Run inside a Linux container with bash 4+:
#   docker run --rm -v "$PWD/extension":/x -w /x ubuntu:24.04 bash test/render-test.sh   (from the repo root)
#
# Optionally set TBOT_BIN to a tbot binary for the container's architecture to
# also check that tbot itself accepts the full rendered configuration.
set -uo pipefail
RENDER="$(dirname "$0")/../src/usr/libexec/kata-identity/render-config"
tmp="$(mktemp -d)"
pass=0 fail=0
base="console=hvc0 cgroup_no_v1=all tbot.proxy=example.teleport.sh:443 tbot.token=beam-tok tbot.secret=0123abcd"

expect_ok() { # NAME CMDLINE GREP...
	local name="$1" cmdline="$2"; shift 2
	printf '%s\n' "${cmdline}" >"${tmp}/cmdline"
	if ! KATA_IDENTITY_CMDLINE="${tmp}/cmdline" bash "${RENDER}" >"${tmp}/out" 2>"${tmp}/err"; then
		echo "FAIL ${name}: exited non-zero: $(cat "${tmp}/err")"; fail=$((fail + 1)); return
	fi
	local pattern
	for pattern in "$@"; do
		grep -qF -- "${pattern}" "${tmp}/out" || { echo "FAIL ${name}: missing '${pattern}'"; fail=$((fail + 1)); return; }
	done
	echo "ok   ${name}"; pass=$((pass + 1))
	cp "${tmp}/out" "${tmp}/${name}.yaml"
}
expect_err() { # NAME CMDLINE STDERR-SUBSTRING
	local name="$1" cmdline="$2" want="$3"
	printf '%s\n' "${cmdline}" >"${tmp}/cmdline"
	if KATA_IDENTITY_CMDLINE="${tmp}/cmdline" bash "${RENDER}" >"${tmp}/out" 2>"${tmp}/err"; then
		echo "FAIL ${name}: expected an error"; fail=$((fail + 1)); return
	fi
	[[ ! -s "${tmp}/out" ]] || { echo "FAIL ${name}: wrote to stdout on error"; fail=$((fail + 1)); return; }
	grep -qF -- "${want}" "${tmp}/err" || { echo "FAIL ${name}: stderr lacks '${want}': $(cat "${tmp}/err")"; fail=$((fail + 1)); return; }
	echo "ok   ${name}  ($(cat "${tmp}/err"))"; pass=$((pass + 1))
}

expect_ok minimal "${base}" "proxy_server: 'example.teleport.sh:443'" "token: 'beam-tok'" \
	"registration_secret: '0123abcd'" "diag_addr: 127.0.0.1:41950" "services: []" "credential_ttl: 1h"
expect_ok full "${base} tbot.app_proxy=8080 tbot.app.grafana=8081 tbot.db.pg=5432:reader:app tbot.db.mongo=27017:agent:admin tbot.ttl=30m tbot.debug=1 tbot.diag_port=42000" \
	"type: application-proxy" "listen: tcp://127.0.0.1:8080" "app_name: 'grafana'" \
	"service: 'pg'" "username: 'reader'" "database: 'app'" "service: 'mongo'" \
	"credential_ttl: 30m" "debug: true" "diag_addr: 127.0.0.1:42000"
expect_ok ipv6-proxy "${base/example.teleport.sh:443/[2001:db8::1]:443}" "proxy_server: '[2001:db8::1]:443'"

expect_err no-proxy "${base/tbot.proxy=example.teleport.sh:443/}" "tbot.proxy is not set"
expect_err no-token "${base/tbot.token=beam-tok/}" "tbot.token is not set"
expect_err no-secret "${base/tbot.secret=0123abcd/}" "tbot.secret is not set"
expect_err bad-proxy "${base/example.teleport.sh:443/example.teleport.sh}" "is not HOST:PORT"
expect_err low-port "${base} tbot.app_proxy=80" "must be 1024-65535"
expect_err dup-port "${base} tbot.app.a=8080 tbot.app.b=8080" "already used by"
expect_err diag-clash "${base} tbot.app_proxy=41950" "already used by"
expect_err bad-ttl "${base} tbot.ttl=forever" "is not like 30m"
# A literal quote and an unexpanded $(id): must be rejected, never rendered.
# shellcheck disable=SC2016
inject='x'"'"'$(id)'
expect_err yaml-inject-token "${base/tbot.token=beam-tok/tbot.token=${inject}}" "invalid characters"
expect_err db-no-user "${base} tbot.db.pg=5432" "expected PORT:USER:DB"
expect_err db-no-db "${base} tbot.db.pg=5432:reader" "expected PORT:USER:DB"
expect_err yaml-inject-db "${base} tbot.db.pg=5432:a'b:app" "invalid database user"
expect_err bad-app-name "${base} tbot.app.-x=8080" "invalid app name"

# tbot must accept the full config: it should get as far as joining, then fail
# only because the (unreachable) proxy refuses the connection.
if [[ -n "${TBOT_BIN:-}" ]]; then
	sed "s#example.teleport.sh:443#127.0.0.1:9#" "${tmp}/full.yaml" >"${tmp}/full-local.yaml"
	mkdir -p /run/kata-identity-tbot
	# Capture first: under pipefail a pipe would report tbot's (expected)
	# timeout/SIGPIPE exit status rather than whether the line appeared.
	tbot_log="$(timeout 15 "${TBOT_BIN}" start -c "${tmp}/full-local.yaml" 2>&1 || true)"
	if grep -q "will attempt to join with provided registration secret" <<<"${tbot_log}"; then
		echo "ok   tbot-accepts-full-config ($("${TBOT_BIN}" version | head -1))"; pass=$((pass + 1))
	else
		echo "FAIL tbot-accepts-full-config"; fail=$((fail + 1))
	fi
fi

echo "---- ${pass} passed, ${fail} failed"
exit $((fail > 0))
