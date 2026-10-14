#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gravitational, Inc.
#
# Build the kata-identity guest extension image with Kata's own image builder
# (tools/osbuilder/image-builder), in its documented extension mode:
# EROFS filesystem + dm-verity hash partition.
#
#   extension/build.sh
#
# Outputs (in build/):
#   kata-identity-extension.img              the extension image (amd64 + arm64)
#   root_hash_identity-extension.txt         its dm-verity parameters, for the
#                                            RuntimeClass guest_extension_images entry
#
# tbot is not stored in this repository: it is downloaded from Teleport's CDN
# for both architectures and checked against Teleport's published SHA-256.
#
# Requires: bash, git, curl, tar, and a Docker engine that can run privileged
# containers with the host's /dev (Linux, or Docker Desktop / OrbStack).
#
# Environment:
#   KATA_VERSION   Kata Containers release whose osbuilder is used (default 4.2.0)
#   TBOT_VERSION   Teleport release tbot is taken from (default 18.11.2); match
#                  your cluster's major version
#   CACHE_DIR      download/checkout cache (default <repo>/.cache)
#   OUT_DIR        output directory (default <repo>/build)
set -euo pipefail

KATA_VERSION="${KATA_VERSION:-4.2.0}"
TBOT_VERSION="${TBOT_VERSION:-18.11.2}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache="${CACHE_DIR:-${repo_root}/.cache}"
out="${OUT_DIR:-${repo_root}/build}"
src="${repo_root}/extension/src"

info() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

for c in git curl tar docker; do command -v "$c" >/dev/null || die "missing required command: $c"; done
mkdir -p "${cache}" "${out}"

# --- Kata osbuilder, at the release tag ----------------------------------------
osbuilder_repo="${cache}/kata-containers-${KATA_VERSION}"
if [[ ! -x "${osbuilder_repo}/tools/osbuilder/image-builder/image_builder.sh" ]]; then
	info "Fetching Kata Containers ${KATA_VERSION} osbuilder"
	rm -rf "${osbuilder_repo}"
	git -c advice.detachedHead=false clone -q --depth 1 --branch "${KATA_VERSION}" --filter=blob:none --sparse \
		https://github.com/kata-containers/kata-containers.git "${osbuilder_repo}"
	git -C "${osbuilder_repo}" sparse-checkout set tools/osbuilder
fi
osbuilder="${osbuilder_repo}/tools/osbuilder"

# --- tbot, both architectures, checksum-verified -------------------------------
tbot_dir="${cache}/tbot-${TBOT_VERSION}"
mkdir -p "${tbot_dir}"
for pair in amd64:x86_64 arm64:aarch64; do
	arch="${pair%%:*}" uname_m="${pair##*:}"
	[[ -x "${tbot_dir}/tbot-${uname_m}" ]] && continue
	tarball="teleport-v${TBOT_VERSION}-linux-${arch}-bin.tar.gz"
	url="https://cdn.teleport.dev/${tarball}"
	info "Downloading ${tarball}"
	curl -fsSL "${url}" -o "${cache}/${tarball}"
	want="$(curl -fsSL "${url}.sha256" | cut -d' ' -f1)"
	got="$(sha256 "${cache}/${tarball}")"
	[[ -n "${want}" && "${got}" == "${want}" ]] || die "${tarball}: SHA-256 mismatch (got ${got}, want ${want})"
	info "  SHA-256 verified: ${got}"
	tar -xzf "${cache}/${tarball}" -C "${tbot_dir}" teleport/tbot
	mv "${tbot_dir}/teleport/tbot" "${tbot_dir}/tbot-${uname_m}"
	rmdir "${tbot_dir}/teleport"
	rm -f "${cache}/${tarball}"
done

# --- builder image: Kata's own image-builder Dockerfile ------------------------
builder="kata-identity-osbuilder:${KATA_VERSION}"
info "Building ${builder} from ${osbuilder}/image-builder"
# --load: with a docker-container buildx builder the result otherwise stays in the
# build cache and never reaches the local image store.
if docker buildx version >/dev/null 2>&1; then
	docker buildx build --load -q -t "${builder}" "${osbuilder}/image-builder" >/dev/null
else
	docker build -q -t "${builder}" "${osbuilder}/image-builder" >/dev/null
fi

# --- assemble the extension rootfs and build the image -------------------------
# The rootfs is assembled inside the container so every file is owned by root
# in the image, whatever the host filesystem does with ownership.
info "Building kata-identity-extension.img (Kata ${KATA_VERSION}, tbot ${TBOT_VERSION})"
docker run --rm --privileged -v /dev:/dev \
	-v "${osbuilder}":/osbuilder:ro \
	-v "${src}":/src:ro \
	-v "${tbot_dir}":/tbot:ro \
	-v "${out}":/out \
	-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
	-e TBOT_VERSION="${TBOT_VERSION}" \
	"${builder}" bash -euo pipefail -c '
		rootfs=$(mktemp -d)
		cp -a /src/. "${rootfs}/"
		install -D -m 0755 /tbot/tbot-x86_64  "${rootfs}/usr/lib/kata-identity/tbot-x86_64"
		install -D -m 0755 /tbot/tbot-aarch64 "${rootfs}/usr/lib/kata-identity/tbot-aarch64"
		echo "${TBOT_VERSION}" > "${rootfs}/usr/lib/kata-identity/TBOT_VERSION"
		chown -R 0:0 "${rootfs}"
		# Note: image_builder.sh stages content in its own mktemp -d directory,
		# so the extension root ends up mode 0700 regardless. The tbot unit
		# copes by bind-mounting only its directory (see common.sh).
		chmod 0755 "${rootfs}"/usr/libexec/kata-identity/{render-config,start} \
		           "${rootfs}"/hooks/prestart/50-kata-identity
		chmod 0644 "${rootfs}"/usr/libexec/kata-identity/common.sh
		rm -f /out/kata-identity-extension.img /out/root_hash_identity-extension.txt
		BUILD_VARIANT=identity-extension FS_TYPE=erofs MEASURED_ROOTFS=yes \
		SKIP_DAX_HEADER=yes SKIP_ROOTFS_CHECK=yes \
			bash /osbuilder/image-builder/image_builder.sh \
			-o /out/kata-identity-extension.img "${rootfs}"
		chown "${HOST_UID}:${HOST_GID}" /out/kata-identity-extension.img /out/root_hash_identity-extension.txt
	'

[[ -s "${out}/root_hash_identity-extension.txt" ]] || die "no dm-verity root hash produced"
info "Done"
printf '  image:        %s (%s)\n' "${out}/kata-identity-extension.img" "$(du -h "${out}/kata-identity-extension.img" | cut -f1)"
printf '  sha256:       %s\n' "$(sha256 "${out}/kata-identity-extension.img")"
printf '  verity_params %s\n' "$(cat "${out}/root_hash_identity-extension.txt")"
