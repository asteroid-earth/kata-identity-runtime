# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gravitational, Inc.
# Library: its variables are used by the scripts that source it.
# shellcheck disable=SC2034
# kata-identity: definitions shared by the extension's scripts.
#
# The extension is mounted read-only by the stock Kata guest at
# /run/kata-extensions/identity/ (kata-extension-mount@identity.service) before
# kata-agent starts. Nothing here writes outside /run.

KI_EXT_ROOT=/run/kata-extensions/identity
KI_LIBEXEC="${KI_EXT_ROOT}/usr/libexec/kata-identity"
KI_STATE_DIR=/run/kata-identity            # guest tmpfs; never shared into containers
KI_CONFIG="${KI_STATE_DIR}/tbot.yaml"
KI_LOG="${KI_STATE_DIR}/hook.log"
KI_UNIT=kata-identity-tbot
KI_TBOT_STORAGE=/run/kata-identity-tbot    # systemd RuntimeDirectory of the unit

# Where the guest kernel command line is read from. Overridable for tests only.
KI_CMDLINE="${KATA_IDENTITY_CMDLINE:-/proc/cmdline}"

# tbot's diagnostics listener (/readyz, /livez, /metrics). Loopback only: it is
# reachable from workload containers (they share the guest's network
# namespace), which lets a workload check readiness, but never from the pod
# network. Override with tbot.diag_port=<port>.
KI_DEFAULT_DIAG_PORT=41950

# One extension image serves amd64 and arm64: it carries both static tbot
# builds and picks the one matching the guest.
KI_TBOT_DIR="${KI_EXT_ROOT}/usr/lib/kata-identity"
KI_TBOT="${KI_TBOT_DIR}/tbot-$(uname -m)"

# A read-only bind of KI_TBOT_DIR that the unprivileged tbot user can reach.
# Extension images built by Kata's image_builder.sh have a mode-0700 root
# directory, which tbot (user nobody) cannot traverse; start binds just this
# (0755) directory here, in the guest's own mount namespace (containers have
# their own /run and never see it). The binary executed is still the
# dm-verity-verified one.
KI_TBOT_BIND_DIR=/run/kata-identity-bin

# ki_cmdline_get KEY: print the value of KEY=VALUE from the kernel command line.
# Returns 1 if the key is absent. A bare KEY (no '=') yields an empty value.
ki_cmdline_get() {
	local key="$1" word words
	read -r -a words <"${KI_CMDLINE}"
	for word in "${words[@]}"; do
		if [[ "${word}" == "${key}="* ]]; then
			printf '%s' "${word#*=}"
			return 0
		elif [[ "${word}" == "${key}" ]]; then
			return 0
		fi
	done
	return 1
}

ki_diag_addr() {
	local port
	port="$(ki_cmdline_get tbot.diag_port || true)"
	printf '127.0.0.1:%s' "${port:-${KI_DEFAULT_DIAG_PORT}}"
}
