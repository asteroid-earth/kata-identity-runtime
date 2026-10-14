#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gravitational, Inc.
#
# Place the extension image on Kata nodes: one Job per node, run deliberately.
# Re-run it when a node joins, or after rebuilding the extension.
#
#   deploy/install.sh IMAGE              all nodes labelled katacontainers.io/kata-runtime=true
#   deploy/install.sh IMAGE NODE...      only the named nodes
#
# IMAGE is the image built from deploy/installer/Dockerfile. Extra kubectl
# arguments (e.g. --context) can be passed in KUBECTL_ARGS.
set -euo pipefail

image="${1:?usage: install.sh IMAGE [NODE...]}"
shift
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2206  # intentional word splitting of extra args
kubectl=(kubectl ${KUBECTL_ARGS:-})
ns=kata-identity-system

if (($# > 0)); then
	nodes=("$@")
else
	read -r -a nodes <<<"$("${kubectl[@]}" get nodes -l katacontainers.io/kata-runtime=true \
		-o jsonpath='{.items[*].metadata.name}')"
fi
((${#nodes[@]})) || { echo "no Kata nodes found (label katacontainers.io/kata-runtime=true)" >&2; exit 1; }

# hostPath writes need the privileged Pod Security level in this namespace.
"${kubectl[@]}" create namespace "${ns}" --dry-run=client -o yaml |
	"${kubectl[@]}" label --local -f - -o yaml pod-security.kubernetes.io/enforce=privileged |
	"${kubectl[@]}" apply -f - >/dev/null

for node in "${nodes[@]}"; do
	"${kubectl[@]}" -n "${ns}" delete job "kata-identity-install-${node}" --ignore-not-found >/dev/null
	sed -e "s#NODE#${node}#g" -e "s#IMAGE#${image}#g" "${here}/installer-job.yaml" |
		"${kubectl[@]}" apply -f - >/dev/null
done

rc=0
for node in "${nodes[@]}"; do
	job="kata-identity-install-${node}"
	if "${kubectl[@]}" -n "${ns}" wait --for=condition=Complete "job/${job}" --timeout=300s >/dev/null 2>&1; then
		printf '%-24s installed  %s\n' "${node}" "$("${kubectl[@]}" -n "${ns}" logs "job/${job}" | cut -c1-80)"
	else
		printf '%-24s FAILED     see: kubectl -n %s describe job/%s\n' "${node}" "${ns}" "${job}"
		rc=1
	fi
done
exit "${rc}"
