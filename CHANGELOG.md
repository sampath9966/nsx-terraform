# Release notes

Every release is on `main`. To take one, on each server:

```bash
cd ~/nsx-generator && git pull        # or just: scripts/update.sh, which pulls for you
scripts/update.sh                     # shows what changes, asks, applies, then fixes up the host
```

That one command is the upgrade for every release below. It shows the notes for
the releases you have not applied yet, previews each file change, and ends by
running `scripts/converge.sh`, which brings the host (CI image, runner, GitLab
container) to what the release expects and tells you plainly about anything it
cannot fix itself. Run it again after fixing whatever it reported.

## 1.2.0

**Pipeline jobs no longer download anything.** The first jobs on a real runner
failed twice over (`Terraform has no command named "sh"`, then `apk add` timing
out on a network that only allows Docker Hub). The pipeline now runs in one image
(`nsx-ci:1`: Python, Terraform, bash, curl, git) that `converge` builds on the
runner host from Docker Hub images alone.

- Fixed: every job failed with `Terraform has no command named "sh"`.
- Fixed: `data` failed on the shipped example data when PyYAML was missing (the
  fallback YAML parser mishandled `{ scope: x, tag: y }`).
- New: `scripts/converge.sh` (run by `update.sh`) builds the CI image, registers
  or repairs the runner, applies proxy / CA / pull-policy settings found on the
  host, restarts GitLab or the runner only when their configuration changed, and
  checks from inside a job container whether Terraform providers can be reached.
- New: the `terraform` validate job reports "providers unreachable" as a
  warning (exit 42), never silently and never as a hard failure. Plan and apply
  need providers; the converge report says what to set. For networks without
  access to registry.terraform.io, set the CI/CD variable `NSX_TF_NETWORK_MIRROR`
  (an internal mirror) or `NSX_TF_FS_MIRROR`.
- New: `deploy/gitlab/ci-network.env` (optional, never overwritten) for proxy
  settings: `NSX_HTTP_PROXY`, `NSX_HTTPS_PROXY`, `NSX_NO_PROXY`. Without it the
  proxy is taken from the shell, then from the Docker daemon.
- New: `update.sh` shows these release notes, and records the release a tree is at.
- Changed: `update.sh` runs `converge.sh` at the end (`--no-converge` skips it).
- First `update.sh` after this release rebuilds nothing you edited: files you
  changed stay as they are and are listed.

Needs on the host: Docker, and a route from Docker to Docker Hub (a proxy
configured for the Docker daemon is fine). The CI image is about 1.6 GB on disk.

## 1.1.0

- `scripts/update.sh`: preview and apply updates to an existing tree.
- `scripts/gitlab-https.sh`: HTTPS on 8443 with an internal CA and automatic renewal.
- Local GitLab: removed the `grafana` setting GitLab 17 rejects; the runner is on
  the host network so it registers against `127.0.0.1`.
