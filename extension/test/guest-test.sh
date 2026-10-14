#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gravitational, Inc.
#
# Run the built extension inside the stock Kata guest userland: the guest's own
# root filesystem booted as a systemd container (kata-agent masked, since there
# is no VM/vsock), with the extension mounted through dm-verity at
# /run/kata-extensions/identity exactly where the guest mounts it. The real
# prestart hook is then run against a simulated kernel command line.
#
#   extension/test/guest-test.sh failure
#       Unreachable proxy: the hook must fail closed, the unit must end
#       "failed", and a later container must fail fast.
#   TBOT_PROXY=host:443 TBOT_TOKEN=name TBOT_SECRET=secret [TEST_APP=app] extension/test/guest-test.sh success
#       Real join: the hook must succeed and the app proxy must listen on loopback;
#       with TEST_APP, an HTTP request to that app through the proxy must return 200.
#
# Requires: build/kata-identity-extension.img and a guest image
# (GUEST_IMAGE, default kata-guest-stock:4.2.0-arm64) made from the stock
# Kata guest rootfs with `docker import`.

# "check && ok || nok" is safe here: ok() always succeeds.
# shellcheck disable=SC2015
set -euo pipefail

mode="${1:?usage: guest-test.sh failure|success}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
img="${repo_root}/build/kata-identity-extension.img"
params="${repo_root}/build/root_hash_identity-extension.txt"
guest_image="${GUEST_IMAGE:-kata-guest-stock:4.2.0-arm64}"
name="kata-identity-guest-test"
[[ -s "${img}" && -s "${params}" ]] || { echo "build the extension first (extension/build.sh)" >&2; exit 1; }

pass=0 fail=0
ok() { echo "ok   $*"; pass=$((pass + 1)); }
nok() { echo "FAIL $*"; fail=$((fail + 1)); }
g() { docker exec "${name}" bash -c "$1"; }

# Partition layout (p1 = EROFS data, p2 = dm-verity hash), read with parted from
# Kata's own builder image, in 512-byte sectors.
read -r p1_start p1_size p2_start < <(docker run --rm -v "${repo_root}/build":/b:ro \
	"${BUILDER_IMAGE:-kata-identity-osbuilder:4.2.0}" parted -s /b/kata-identity-extension.img unit s print |
	awk '$1==1{gsub(/s/,""); s1=$2; z1=$4} $1==2{gsub(/s/,""); s2=$2} END{print s1, z1, s2}')
[[ -n "${p2_start:-}" ]] || { echo "could not read the extension partition table" >&2; exit 1; }

docker rm -f "${name}" >/dev/null 2>&1 || true
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { # dm-verity mapping and loop devices live in the (shared) host kernel
	docker exec "${name}" bash -c 'systemctl stop kata-identity-tbot 2>/dev/null
		umount /run/kata-identity-bin 2>/dev/null
		umount /run/kata-extensions/identity 2>/dev/null
		veritysetup close extension-identity 2>/dev/null
		for l in $(losetup -j /build/kata-identity-extension.img | cut -d: -f1); do losetup -d "$l"; done' >/dev/null 2>&1 || true
	docker rm -f "${name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker run -d --privileged --name "${name}" \
	--tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
	-v "${repo_root}/build":/build:ro \
	"${guest_image}" /sbin/init systemd.mask=kata-agent.service systemd.unit=multi-user.target >/dev/null
for _ in $(seq 1 30); do g 'systemctl is-system-running 2>/dev/null' | grep -qE 'running|degraded' && break; sleep 1; done
echo "guest: $(g 'systemctl --version | head -1'), state $(g 'systemctl is-system-running' || true)"

# Mount the extension the way kata-extension-mount.sh does: dm-verity, then EROFS, read-only.
g "set -e
	vp=\$(cat /build/root_hash_identity-extension.txt)
	get() { echo \"\$vp\" | tr ',' '\n' | sed -n \"s/^\$1=//p\"; }
	d=\$(losetup -f --show -r -o $((p1_start * 512)) --sizelimit $((p1_size * 512)) /build/kata-identity-extension.img)
	h=\$(losetup -f --show -r -o $((p2_start * 512)) /build/kata-identity-extension.img)
	veritysetup open --no-superblock --salt=\$(get salt) --data-blocks=\$(get data_blocks) \
		--data-block-size=4096 --hash-block-size=4096 \$d extension-identity \$h \$(get root_hash)
	mkdir -p /run/kata-extensions/identity
	mount -t erofs -o ro /dev/mapper/extension-identity /run/kata-extensions/identity" &&
	ok "extension mounted through dm-verity at /run/kata-extensions/identity" || { nok "extension mount"; exit 1; }

hook() { # CMDLINE -> runs the prestart hook as kata-agent would; prints rc
	docker exec -e KATA_IDENTITY_CMDLINE=/tmp/cmdline "${name}" bash -c \
		"printf '%s\n' '$1' >/tmp/cmdline; /run/kata-extensions/identity/hooks/prestart/50-kata-identity </dev/null" 2>&1
}

case "${mode}" in
failure)
	cmdline="console=hvc0 tbot.proxy=127.0.0.1:9 tbot.token=t tbot.secret=s tbot.timeout=25"
	t0=${SECONDS}
	if out="$(hook "${cmdline}")"; then nok "hook succeeded against an unreachable proxy"; else ok "hook failed closed after $((SECONDS - t0))s: ${out}"; fi
	g "systemctl is-failed --quiet kata-identity-tbot" && ok "unit kata-identity-tbot ended 'failed' (start limit)" ||
		nok "unit state: $(g 'systemctl show -p ActiveState --value kata-identity-tbot')"
	# Only tbot's own log lines: systemd's "Started ..." entries are logged as root.
	# shellcheck disable=SC2016  # $(uname -m) expands inside the guest
	user="$(g 'journalctl -u kata-identity-tbot _COMM=tbot-$(uname -m) -o export --no-pager | sed -n "s/^_UID=//p" | sort -u | paste -sd,')"
	[[ "${user}" == 65534 ]] && ok "tbot ran as nobody (uid 65534)" || nok "tbot uid: '${user}'"
	g 'journalctl -u kata-identity-tbot --no-pager | grep -q "Initializing tbot"' &&
		ok "tbot executed via the bind-mounted dm-verity directory" || nok "tbot never started"
	t0=${SECONDS}
	if out="$(hook "${cmdline}")"; then nok "second container succeeded"; else ok "second container failed fast ($((SECONDS - t0))s): ${out}"; fi
	g 'stat -c "%a %U:%G" /run/kata-identity/tbot.yaml' | grep -q "640 root:nogroup" && ok "config is 0640 root:nogroup" || nok "config perms"
	;;
success)
	: "${TBOT_PROXY:?}" "${TBOT_TOKEN:?}" "${TBOT_SECRET:?}"
	cmdline="console=hvc0 tbot.proxy=${TBOT_PROXY} tbot.token=${TBOT_TOKEN} tbot.secret=${TBOT_SECRET} tbot.app_proxy=8080 tbot.timeout=90"
	t0=${SECONDS}
	if out="$(hook "${cmdline}")"; then ok "hook succeeded: tbot joined and is ready ($((SECONDS - t0))s)"; else nok "hook: ${out}"; g 'journalctl -u kata-identity-tbot --no-pager | tail -20'; fi
	g 'exec 3<>/dev/tcp/127.0.0.1/41950 && printf "GET /readyz HTTP/1.0\r\n\r\n" >&3 && cat <&3' | grep -qE '"status": ?"healthy"' &&
		ok "/readyz on 127.0.0.1:41950 reports healthy" || nok "/readyz not healthy"
	g 'exec 3<>/dev/tcp/127.0.0.1/8080' && ok "app proxy listening on 127.0.0.1:8080" || nok "app proxy not listening"
	if [[ -n "${TEST_APP:-}" ]]; then # an app the bot's role allows: request it through the proxy
		status="$(g "exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET http://${TEST_APP}/ HTTP/1.1\r\nHost: ${TEST_APP}\r\nConnection: close\r\n\r\n' >&3 && head -1 <&3")"
		[[ "${status}" == *" 200 "* ]] && ok "GET http://${TEST_APP}/ via the app proxy: ${status%$'\r'}" || nok "app request: ${status}"
	fi
	t0=${SECONDS}
	if hook "${cmdline}" >/dev/null; then ok "second container passes immediately ($((SECONDS - t0))s)"; else nok "second container"; fi
	g 'journalctl -u kata-identity-tbot --no-pager | grep -m1 -E "Fetched new bot identity|Identity initialized"' | cut -c1-160
	;;
*) echo "unknown mode ${mode}" >&2; exit 2 ;;
esac

echo "---- ${pass} passed, ${fail} failed"
exit $((fail > 0))
