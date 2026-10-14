#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gravitational, Inc.
#
# Show the Teleport identity of a kata-identity pod, from inside the pod:
# call the echo app through tbot's loopback app proxy, then decode the signed
# JWT Teleport attached to the request.
#
#   examples/echo/check-identity.sh <pod> [kubectl args, e.g. -n NAMESPACE]
#
# The pod needs tbot.app_proxy=8080 (as in examples/alpine.yaml) and a role
# that allows the kata-identity-echo app.
set -eu
pod="${1:?usage: check-identity.sh <pod> [kubectl args]}"
shift

# The quoted script runs inside the pod, so nothing in it expands here.
# shellcheck disable=SC2016
kubectl "$@" exec "${pod}" -- sh -c '
	jwt=$(http_proxy=http://127.0.0.1:8080 wget -qO- http://kata-identity-echo/ |
		sed -n "s/^Teleport-Jwt-Assertion: //p" | tr -d "\r")
	[ -n "$jwt" ] || { echo "no Teleport JWT: is tbot.app_proxy=8080 set and the app allowed?" >&2; exit 1; }
	p=$(echo "$jwt" | cut -d. -f2 | tr "_-" "/+")
	while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
	echo "$p" | base64 -d; echo'
