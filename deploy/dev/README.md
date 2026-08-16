# Dev Environment

One-click local stack: Postgres, Redis, MinIO, Traefik, Gitea, Backend, Runner, Relay, plus a local Next.js frontend with hot reload.

## Quick start

```bash
bazel run //deploy/dev:up                # docker infra + host backend/relay/runner + frontends
bazel run //deploy/dev:up_prod_frontend  # same stack, but frontend is built then served
bazel run //deploy/dev:backend_only      # CI-style: skip frontends
bazel run //deploy/dev:clean             # stop and wipe volumes
bazel run //deploy/dev:reset_runners     # restart host runner+relay
bazel run //deploy/dev:rebuild_runner    # rebuild runner binary + restart host runner
```

`./dev.sh [--clean|--reset-runners|...]` still works — same flags, same behavior.

The script auto-generates `.env` with worktree-hashed ports so multiple worktrees can coexist. Actual ports are printed on startup (or read from `deploy/dev/.env`).

Test accounts seeded by `init-seed.sh`:

- **User**: `dev@agentsmesh.local` / `devpass123`
- **Admin**: `admin@agentsmesh.local` / `adminpass123`

## Contributors in mainland China

Docker image pulls through `docker.io` can be slow or unreliable from mainland China. **Configure registry mirrors once on your machine** — the Dockerfiles in this repo intentionally use canonical image names so this works transparently, with automatic fallback to Docker Hub when a mirror is unavailable.

Edit `~/.docker/daemon.json` (Docker Desktop) or `/etc/docker/daemon.json` (Linux), then restart Docker:

```json
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io",
    "https://dockerproxy.com"
  ]
}
```

Do **not** hard-code mirror prefixes into the Dockerfiles — mirror metadata occasionally drifts out of sync with Docker Hub, which breaks builds for *everyone* and can't be fixed without a repo change. The daemon-level config is per-machine, auto-falls-back, and doesn't affect non-China contributors.

## Logs

```bash
tail -f deploy/dev/runtime/backend/backend.log   # ibazel + backend stdout
tail -f deploy/dev/runtime/relay/relay.log
tail -f deploy/dev/runtime/runner/runner.log
tail -f deploy/dev/web.log                       # bazel next_dev / next_start (web)
docker compose logs -f postgres                  # docker infra
```

## Common issues

**Port conflicts between worktrees**: ports are derived from the worktree directory name. If you see a port clash, it usually means two worktrees hashed to the same port — rename one or set `PORT_SEED` in `.env`.

**`docker compose build` fails with `failed to resolve source metadata ... not found`**: Your Docker daemon is routing through a broken registry mirror. See the China section above — either fix the mirror list in `daemon.json` or remove it entirely to use Docker Hub directly.

**Codex pod prints `bwrap: No permissions to create a new namespace`**: keep Codex sandboxing enabled. On Linux, enable unprivileged user namespaces on the host:

```bash
sudo sysctl -w kernel.unprivileged_userns_clone=1
echo 'kernel.unprivileged_userns_clone=1' | sudo tee /etc/sysctl.d/99-agentsmesh-codex.conf
sudo sysctl --system
```

The dev runner also enables Codex's legacy Landlock sandbox fallback. It runs on the host and writes pod worktrees to `../AgentsMesh-Pods/<worktree>` by default. Override that with `HOST_RUNNER_WORKSPACE_ROOT=/path/to/workspaces`.

**Codex keeps asking for ChatGPT login**: host runner uses an isolated HOME at `deploy/dev/runtime/runner/home`, so it does not read your normal `~/.codex/auth.json` unless you opt in. To reuse your host Codex login for dev pods, start or restart with:

```bash
AGENTSMESH_DEV_SYNC_CODEX_AUTH=true ./dev.sh --rebuild-runner
```

**Runner can't connect to backend**: check `GRPC_PUBLIC_ENDPOINT` in the generated `.env`. For local (non-Docker) runners, this must be reachable from the host — usually `grpcs://localhost:<GRPC_PORT>`.
