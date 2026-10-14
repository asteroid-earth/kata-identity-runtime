# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Gravitational, Inc.
# Carries the extension image to the nodes (see deploy/install.sh).
# Build from the repo root after extension/build.sh:
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     -f deploy/installer/Dockerfile -t REGISTRY/kata-identity-extension:TAG --push .
FROM busybox:1.37
COPY build/kata-identity-extension.img build/root_hash_identity-extension.txt /
