# kata-identity guest extension

A [Kata Containers](https://katacontainers.io) **guest extension image** that gives
every pod on a RuntimeClass a short-lived [Teleport](https://goteleport.com) identity,
issued by `tbot` running **inside the pod's microVM but outside all of its containers**.

The stock Kata guest image is not modified. Kata 4.x composable images mount any
configured extension read-only at `/run/kata-extensions/<name>/` before `kata-agent`
starts. This extension supplies `tbot` and an OCI prestart hook. The hook starts `tbot`
and holds every container until `tbot` reports ready.

```
Kata VM (stock guest)
├─ systemd ─ kata-extension-mount@identity  → /run/kata-extensions/identity (EROFS, dm-verity)
├─ kata-agent ─ CreateContainer ─ prestart hook (this extension)
│                                   ├─ first container: render config from /proc/cmdline,
│                                   │   start tbot as a transient systemd unit (user nobody)
│                                   └─ every container: wait for tbot /readyz, else fail
├─ tbot (unit kata-identity-tbot) → loopback listeners: app proxy, app/db tunnels, /readyz
└─ workload container (any image) → 127.0.0.1:<port>; never sees keys or certificates
```

## Contents

| Path (under the extension root) | Purpose |
|---|---|
| `hooks/prestart/50-kata-identity` | OCI prestart hook. Fails the container if `tbot` isn't ready in time. |
| `usr/libexec/kata-identity/start` | Starts `tbot` once per VM via `systemd-run`, hardened (user `nobody`, no capabilities, read-only system, private tmp). It first bind-mounts the extension's `tbot` directory read-only at `/run/kata-identity-bin`, because Kata's image builder gives extension roots mode `0700`, which `nobody` can't traverse. |
| `usr/libexec/kata-identity/render-config` | Builds `tbot.yaml` from `tbot.*` kernel command-line parameters. Every value is validated, and it fails closed. |
| `usr/libexec/kata-identity/common.sh` | Shared paths and helpers. |
| `usr/lib/kata-identity/tbot-x86_64`, `tbot-aarch64` | Static `tbot` builds, **downloaded by `build.sh`** from Teleport's CDN and checked against Teleport's published SHA-256. They aren't stored in this repository. One image serves amd64 and arm64, so one dm-verity root hash serves a mixed cluster. |

## Configuration: the guest kernel command line

Cluster-wide values go in the RuntimeClass's Kata drop-in (`kernel_params`). Per-pod
values go in the pod annotation `io.katacontainers.config.hypervisor.kernel_params`,
which the Kata runtime merges by key into the RuntimeClass values.

| Parameter | Where | Meaning |
|---|---|---|
| `tbot.proxy=HOST:PORT` | RuntimeClass | Teleport Proxy address. Required. |
| `tbot.token=NAME` | pod | `bound_keypair` join token name. Required. |
| `tbot.secret=SECRET` | pod | That token's one-time registration secret. Required. |
| `tbot.app_proxy=PORT` | pod | HTTP proxy to every app the bot may access, on `127.0.0.1:PORT`. |
| `tbot.app.NAME=PORT` | pod | Tunnel to Teleport app `NAME` on `127.0.0.1:PORT`. |
| `tbot.db.SERVICE=PORT:USER:DB` | pod | Tunnel to database `SERVICE` (as `USER`, database `DB`) on `127.0.0.1:PORT`. |
| `tbot.ttl=DURATION` | either | Certificate TTL, e.g. `30m` (default `1h`). |
| `tbot.timeout=SECONDS` | either | How long each container waits for `tbot` (default `120`). |
| `tbot.diag_port=PORT` | either | `tbot` diagnostics port on loopback (default `41950`). |
| `tbot.debug=1` | either | Verbose `tbot` logging. |

Ports must be 1024–65535 and unique; `tbot` runs unprivileged.

## Security notes

- **The workload can read `/proc/cmdline`, including `tbot.secret`.** That's acceptable
  only because a `bound_keypair` registration secret is single-use: `tbot`'s first join
  consumes it before any workload process starts. Create one token per pod, with
  recovery limit 1.
- **`tbot` keeps everything on guest tmpfs that's never shared into a container:** its
  config, keypair and certificates. Workloads get capabilities (loopback listeners), not
  credentials.
- **The diagnostics listener (`/readyz`, `/livez`, `/metrics`) is reachable from
  workloads** over loopback. It isn't reachable from the pod network.
- **This isolates the identity from the workload, not from the node.** Guest memory
  lives on the host. Protecting against the node needs confidential containers.
- **Kubernetes access isn't provided.** `tbot` has no loopback listener for it.

## Build

```bash
extension/build.sh        # KATA_VERSION=4.2.0 TBOT_VERSION=18.11.2 by default
```

This fetches Kata's `tools/osbuilder` at `KATA_VERSION` and `tbot` at `TBOT_VERSION`
(SHA-256 verified). It then runs Kata's own `image_builder.sh` in its extension mode:
EROFS filesystem plus a dm-verity hash partition. The outputs go to `build/`:

- `kata-identity-extension.img`
- `root_hash_identity-extension.txt`: the `verity_params` value for the RuntimeClass

Match `TBOT_VERSION` to your Teleport cluster's major version. Building needs a Docker
engine that can run privileged containers with the host's `/dev` (Linux, Docker
Desktop or OrbStack).

## Tests

`render-test.sh` checks the config renderer. `guest-test.sh` boots the **stock Kata guest
root filesystem** as a systemd container, mounts the built extension through dm-verity,
and runs the real hook, covering both the fail-closed path and a real join.

```bash
extension/test/guest-test.sh failure
TBOT_PROXY=host:443 TBOT_TOKEN=name TBOT_SECRET=secret TEST_APP=app extension/test/guest-test.sh success
docker run --rm -v "$PWD":/x -w /x ubuntu:24.04 bash test/render-test.sh
# also check that tbot accepts the rendered config (binary for the container's arch):
docker run --rm -v "$PWD":/x -v "$PWD/../.cache/tbot-18.11.2":/t -w /x \
  -e TBOT_BIN=/t/tbot-aarch64 ubuntu:24.04 bash test/render-test.sh
docker run --rm -v "$PWD":/x -w /x koalaman/shellcheck:stable -x -s bash \
  src/usr/libexec/kata-identity/{common.sh,render-config,start} test/render-test.sh
```

## License

Apache License 2.0; see [LICENSE](../LICENSE). `tbot` is Teleport software, downloaded at
build time under Teleport's own license, and isn't part of this repository.
