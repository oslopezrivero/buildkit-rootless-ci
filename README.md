# Rootless BuildKit for GitLab CI

*[Leer en español](README.es.md)*

Build container images in GitLab CI **without privileged jobs and without the host's Docker socket**.

Docker-in-Docker is the usual recipe, but it needs `privileged: true` (or a mounted `/var/run/docker.sock`).
In practice, anyone who can push a branch can run code with near-full control of the runner host, and of
everything else that runs there.

This repository is a small, tested reference setup that replaces it:

```
 GitLab Runner (privileged = false, no docker.sock)
   ├─ group A jobs ──mTLS (CA A)──▶ buildkitd-team-a ─┐
   └─ group B jobs ──mTLS (CA B)──▶ buildkitd-team-b ─┴─▶ registry
```

- **One rootless BuildKit daemon per group** of projects, on its own Docker network, with no published ports.
- **Mutual TLS with one CA per group.** A client certificate from group A is rejected by group B's daemon.
- **Unprivileged runners**: `privileged = false`, no `docker.sock`.
- **A reusable CI/CD component**: each project includes it in a few lines; improvements are made once.
- **An audit script** that flags pipelines that drift back to Docker-in-Docker.

## Contents

| Path | What it is |
|---|---|
| `buildkitd/docker-compose.yml` | Rootless `buildkitd` for one group (resource limits, healthcheck, no ports) |
| `buildkitd/gen-certs.sh` | Creates the group's CA, server and client certificates |
| `templates/buildkit-build.yml` | GitLab CI/CD component: build and push with `buildctl` over mTLS, with registry cache |
| `gitlab/config.toml.example` | Runner section: unprivileged, no socket, attached to the group network |
| `scripts/audit-dind.py` | Scans CI files for `docker:dind`, `privileged: true`, the Docker socket and `docker build` |
| `test/` | End-to-end test on a local Docker host, plus audit fixtures |

## Quick start

```bash
cd buildkitd
sudo ./gen-certs.sh team-a                    # certs/ for buildkitd-team-a
GROUP=team-a docker compose up -d --wait      # daemon on network team-a-ci
```

Then:

1. Point the group's runner at that network (`network_mode = "team-a-ci"`, see `gitlab/config.toml.example`).
2. Add group CI/CD variables: `BUILDKIT_HOST=tcp://buildkitd-team-a:1234`, and `BUILDKIT_CA_PEM`,
   `BUILDKIT_CLIENT_CERT`, `BUILDKIT_CLIENT_KEY` as **File** variables with `ca.pem`, `client.pem`, `client-key.pem`.
3. Publish `templates/buildkit-build.yml` as a CI/CD catalog component and include it:

```yaml
include:
  - component: $CI_SERVER_FQDN/platform/buildkit-rootless-ci/buildkit-build@1
    inputs:
      dockerfile: docker/app.Dockerfile
```

Repeat with another group name for each team: separate CA, network and limits.

## Test it

```bash
test/run.sh     # needs Docker; leaves nothing behind
test/audit.sh   # no Docker needed
```

`test/run.sh` starts two daemons with different CAs and checks that:

1. group A builds an image over mTLS,
2. the image and its build cache are pushed to a registry with the same flags as the component,
3. group B's daemon rejects group A's client certificate.

## Lessons learned

1. **Migrate in stages.** One group first, make it stable, then move on.
2. **Watch registry permissions.** Sharing a daemon or cache across projects can make BuildKit try a
   cross-repository blob mount that the job token is not allowed to do. The registry answers
   `insufficient_scope`, which does not explain the cause. Keep one daemon per group, or add the
   consuming projects to the source project's CI/CD job token allowlist.
3. **Make sure it doesn't come back.** Templates copied from the internet ship with Docker-in-Docker.
   Run `scripts/audit-dind.py` on a schedule over your repositories.
4. **Mind your alerts.** An alert that is always red gets ignored. Fail the audit only on the branches
   that matter (main, release) and keep the rest as a report.

## Notes

- `--oci-worker-no-process-sandbox` plus `seccomp=unconfined` / `apparmor=unconfined` is how the official
  rootless image runs without a privileged container. Builds still run in an unprivileged user namespace.
- On a fixed runner network, GitLab `services:` aliases do not resolve, so `docker:dind` stops working there.
  That is intended.
- Keep `ca-key.pem` offline. Rotate by regenerating the group's certificates and updating its CI variables.

## Author

Omar López Rivero, Infrastructure & Platform Lead.
[LinkedIn](https://www.linkedin.com/in/omar-salvador-l%C3%B3pez-rivero-023718136/)

MIT License.
