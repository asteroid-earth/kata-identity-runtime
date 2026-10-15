# kata-identity-runtime

**Runtime identity for any container.** Pods on the `kata-identity` RuntimeClass run in a
[Kata Containers](https://katacontainers.io) microVM that already holds a short-lived
[Teleport](https://goteleport.com) identity before the container starts. The container
image needs no changes and never sees a key. It reaches Teleport-protected apps, MCP
servers and databases through `tbot` listeners on `127.0.0.1`.

```
Kata microVM (stock guest image)
├─ identity extension (read-only, dm-verity) ── tbot, outside every container
│    prestart hook: start tbot, block each container until tbot is ready
└─ your container (any image) ──> 127.0.0.1:<port> ──> Teleport ──> apps / MCP / DBs
```

Only stock Kata 4.x mechanisms are used: a
[composable guest extension image](https://github.com/kata-containers/kata-containers/blob/4.2.0/docs/design/composable-vm-images.md),
an OCI guest hook and kernel parameters. Details: [extension/README.md](extension/README.md).

## Repository layout

| Directory | Contents | Used in |
|---|---|---|
| `extension/` | The guest extension. `src/` is its contents (the prestart hook and the `tbot` start and config scripts). `build.sh` downloads `tbot` and builds the image with Kata's image builder. `test/` has the config-renderer tests and a test that runs the extension in the stock Kata guest userland. Its [README](extension/README.md) is the reference for all `tbot.*` options. | step 1 |
| `deploy/` | Cluster installation. `installer/Dockerfile` packages the built image. `install.sh` runs `installer-job.yaml` once per Kata node, copying the image to `/opt/kata-identity/`; nothing stays running. `kata-deploy-values.yaml` holds the Helm values that add the `kata-identity` RuntimeClass to kata-deploy. | steps 2–3 |
| `teleport/` | Teleport resources: `role.yaml` (what workloads may reach), `bot.yaml` (the identity pods act as), `token.yaml` (a single-use join token per pod). | steps 4–5 |
| `examples/` | `alpine.yaml` is an unmodified alpine container with an identity (the client). `echo/` is an optional, ordinary (non-Kata) echo app published through Teleport as a call target, plus `check-identity.sh` to show a pod's identity. | step 5, optional |
| `build/`, `.cache/` | Created by `extension/build.sh` and not committed. `build/` holds the output (`kata-identity-extension.img` and its dm-verity parameters). `.cache/` holds the downloaded `tbot` binaries and Kata `osbuilder` checkout. | steps 1–3 |

## What changes in your cluster

**Added:**

- **A file on each Kata node:** `/opt/kata-identity/kata-identity-extension.img`. It's an
  add-on disk image (tbot plus the hook, dm-verity protected), *not* a replacement guest
  rootfs. `deploy/install.sh` places it with one short-lived Job per node, in namespace
  `kata-identity-system`. Nothing stays running.
- **One kata-deploy custom runtime:** the `kata-identity` RuntimeClass and handler. Its
  config is the stock `qemu-runtime-rs` config plus a drop-in that attaches the extension
  and sets the hook path and `tbot.proxy`. kata-deploy adds the handler to the containerd
  config it already manages.
- **In Teleport:** one role, one bot, and a single-use token per pod.

**Unchanged:**

- Existing RuntimeClasses, shims and their configs; pods using them behave as before.
- The stock Kata guest image and kernel, and the existing files under `/opt/kata`.
  kata-deploy only adds the new runtime's own config there.

**Disruption:** the `helm upgrade` in step 3 rolls the kata-deploy DaemonSet, restarting
containerd on each node, one at a time. Schedule it like any containerd restart.

**To remove:**

1. `helm upgrade` the kata-deploy release with `--reuse-values --set customRuntimes.enabled=false`,
   or with your previous values.
2. Delete `/opt/kata-identity/` on the nodes, and the `kata-identity-system` namespace.
3. In Teleport: `tctl bots rm kata-identity`, `tctl rm role/kata-identity-agent`, and
   `tctl rm token/<name>` for any unused tokens.

## Prerequisites

- A running Kubernetes cluster that can run **Kata ≥ 4.2.0**, installed with the
  `kata-deploy` Helm chart (the `qemu-runtime-rs` shim; amd64 or arm64 nodes).
- `kubectl`, `helm` and `jq`.
- A Teleport cluster (≥ 18.1, for `bound_keypair` joining) and `tctl` logged in as a user
  with the **`editor`** role.
- A build host with Docker able to run privileged containers (Linux, Docker Desktop or
  OrbStack), and a container registry your nodes can pull from.

## 1. Build the extension

```bash
extension/build.sh
```

This downloads `tbot` (SHA-256 verified) and builds `build/kata-identity-extension.img`,
plus `build/root_hash_identity-extension.txt` (its dm-verity parameters). Set
`TBOT_VERSION` to match your Teleport cluster (default `18.11.2`).

## 2. Install it on the Kata nodes

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -f deploy/installer/Dockerfile -t $REGISTRY/kata-identity-extension:v1 --push .
deploy/install.sh $REGISTRY/kata-identity-extension:v1
```

This runs one Job per Kata node and prints the dm-verity root hash each node now has.
It's a deliberate action: re-run it when a Kata node joins (`deploy/install.sh IMAGE NODE`)
or after rebuilding the extension.

## 3. Add the `kata-identity` RuntimeClass

```bash
sed -e "s#TELEPORT_PROXY#example.teleport.sh:443#" \
    -e "s#VERITY_PARAMS#$(cat build/root_hash_identity-extension.txt)#" \
    deploy/kata-deploy-values.yaml > /tmp/kata-identity-values.yaml
helm upgrade kata-deploy oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --version 4.2.0 -n <kata-deploy-namespace> --reuse-values -f /tmp/kata-identity-values.yaml
kubectl get runtimeclass kata-identity
```

kata-deploy rolls node by node and restarts containerd on each one. Rebuilding the
extension changes `VERITY_PARAMS`, so repeat steps 2 and 3 after a rebuild.

## 4. Create the Teleport bot and role

Edit `teleport/role.yaml` to select the apps and databases workloads may reach, then:

```bash
tctl create -f teleport/role.yaml
tctl create -f teleport/bot.yaml
```

## 5. Run an identified container

Each pod needs its own single-use join token:

```bash
TOKEN=kata-identity-$(date +%s)
sed "s/kata-identity-example/$TOKEN/" teleport/token.yaml | tctl create -f /dev/stdin
SECRET=$(tctl get token/$TOKEN --format=json | jq -r '.[0].status.bound_keypair.registration_secret')
sed -e "s/TOKEN_NAME/$TOKEN/" -e "s/REGISTRATION_SECRET/$SECRET/" examples/alpine.yaml | kubectl apply -f -
```

Check it:

```bash
kubectl logs identity-demo                      # tbot status: "healthy"
kubectl exec identity-demo -- env http_proxy=http://127.0.0.1:8080 wget -qO- http://<app-name>/
tctl bots instances list kata-identity         # one instance per pod
```

The pod never starts without its identity. If `tbot` can't join (bad token, secret
already used, proxy unreachable), container creation fails.

## See the identity (optional)

Add an echo app published through Teleport. A request to it shows the signed identity
Teleport attaches. This needs a Teleport Application Service; the example installs one.

The echo app is **not** a Kata pod. It's an ordinary pod (normal runtime) published by a
Teleport Application Service. It stands in for whatever an AI agent calls, such as an
internal API or an MCP server. The alpine pod is the client; the echo app is the
destination, and it simply echoes back the identity Teleport attached to the request.

```bash
helm repo add teleport https://charts.releases.teleport.dev
kubectl apply -f examples/echo/echo.yaml
APP_TOKEN=$(tctl tokens add --type=app --ttl=15m --format=text)
sed "s#TELEPORT_PROXY#example.teleport.sh:443#" examples/echo/app-service-values.yaml > /tmp/echo-values.yaml
helm install kata-identity-echo-agent teleport/teleport-kube-agent -n kata-identity-demo \
  -f /tmp/echo-values.yaml --set joinParams.tokenName=$APP_TOKEN
examples/echo/check-identity.sh identity-demo
```

```json
{"iss":"example.teleport.sh","sub":"bot-kata-identity","roles":["kata-identity-agent"],"exp":...}
```

## Per-pod options

All options go in the pod annotation `io.katacontainers.config.hypervisor.kernel_params`:

| Option | Gives the container |
|---|---|
| `tbot.app_proxy=PORT` | An HTTP proxy to every app the role allows: `http://<app-name>/` |
| `tbot.app.NAME=PORT` | A tunnel to one app on `127.0.0.1:PORT` |
| `tbot.db.SERVICE=PORT:USER:DB` | A tunnel to a database on `127.0.0.1:PORT` |
| `tbot.ttl=30m` | A shorter certificate TTL (default `1h`) |

See [extension/README.md](extension/README.md) for the full list.

## Limits

- **Protects the identity from the workload, not from the node.** That needs
  confidential containers.
- **The workload can read its pod's `tbot.secret`.** That's harmless because the secret is
  spent on first join, before the container starts. Always use one token per pod.
- **No Kubernetes or SSH access** through `tbot` listeners.

## License

Copyright 2026 Gravitational, Inc. Licensed under the Apache License 2.0; see [LICENSE](LICENSE).
`tbot` is downloaded at build time under Teleport's license.
