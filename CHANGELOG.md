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

## 1.2.8

Hardening found in a review before production use. Nothing here changes data, and a tree on Vault needs no action.

**Terraform now trusts the CAs it needs, so plan jobs no longer fail with `x509: certificate signed by unknown authority`.** `scripts/tf.sh` builds a bundle from the system roots plus two optional CAs and sets `SSL_CERT_FILE` for the run: the CA of a GitLab that serves its own certificate (the runner already gives every job this as `CI_SERVER_TLS_CA_FILE`; git and curl used it, Terraform did not), and the CA that signed your NSX managers' certificates, given as a CI/CD variable `NSX_CA_FILE` of type File. A missing or non-PEM `NSX_CA_FILE` stops the run with a clear error instead of failing later in TLS. An `SSL_CERT_FILE` you set yourself is left alone, and the temporary bundle is removed when the run ends. Run by hand outside CI, set `SSL_CERT_FILE` to a bundle that holds your CAs.

**Credential selection from CI/CD variables is stricter and explains itself.** `scripts/with-credentials.sh --from env` with nothing set used to die with `invalid variable name`; it now says what it looked for, in order, for the job's scope (for example `NSX_HYD_GM01_PLAN_USERNAME`, `NSX_PLAN_USERNAME`, `NSX_USERNAME`) and reminds you that protected variables are not visible to merge request pipelines. A blank or whitespace-only value no longer counts as a credential. A plan job never falls back to the apply credential, or the other way round.

**`scripts/update.sh` repeats any file it kept.** A file that differs from the generator is kept unless you pass `--overwrite-unknown`, and it was listed only in the middle of a long diff, so "applied N change(s)" read as complete while part of the release was not in effect. Every run that kept one now ends with an ATTENTION block naming the files and the exact command. Exit statuses are unchanged.

**Smaller:** `scripts/readiness.sh` stops if it cannot change into the repository, `make ready` and the GitLab setup summary describe both credential options and `NSX_CA_FILE`, and the docs state plainly that unprotected plan variables are visible to anyone who can run a pipeline on the project, so the plan account must be read-only. Variable-based credentials are wired for GitLab; the generated GitHub workflow still uses Vault.

## 1.2.7

**NSX credentials can come from masked GitLab CI/CD variables, with nothing stored on the runner host.** `scripts/with-credentials.sh` now defaults to `--from auto`: Vault when `VAULT_ADDR` is set (unchanged), otherwise the environment, otherwise an error that names the variables to set. In the environment the first complete pair wins: `NSX_<SITE>_<SCOPE>_USERNAME` / `_PASSWORD`, then `NSX_<SITE>_...`, then `NSX_<SCOPE>_...`, then `NSX_USERNAME` / `NSX_PASSWORD`, where SITE is the manager key upper-cased (`hyd-gm01` becomes `HYD_GM01`) and SCOPE is `PLAN` or `APPLY`. The generated plan and apply jobs set `NSX_CRED_SCOPE`, so a read-only NSX account can sit in unprotected `NSX_PLAN_*` variables for merge request plans and the write account in protected `NSX_APPLY_*` variables. The GitLab state backend needs no secret: jobs use `CI_JOB_TOKEN`. Existing Vault setups need no change.

## 1.2.6

**On a GitLab merge request, the `managers` job failed with "downstream pipeline can not be created, the resulting pipeline would have been empty".** A child pipeline of a merge request pipeline is itself a merge request pipeline. Jobs with no `rules` default to `only: branches, tags`, which GitLab leaves out of one, so every generated plan job was filtered out even though `generated-pipeline.yml` was valid. The generated child pipeline now starts with `workflow: rules: - when: always`. After `scripts/update.sh`, push a new commit to the merge request to get a fresh pipeline.

## 1.2.5

**Git clone failed with `Problem with the SSL CA cert (path? access rights?)`.** Git was pointed at `CI_SERVER_TLS_CA_FILE` on a path the helper could not read. Registration now copies that file into the helper temp dir before fetch and sets `sslCAInfo` only for this GitLab URL. The bundle installed in the runner is chmod 644, and converge refuses to register if `/etc/gitlab-runner/certs/<GITLAB_HOST>.crt` is missing or not PEM. GitLab on another host: copy its `ca.crt` onto the runner machine and set `NSX_GITLAB_CA_FILE` in `deploy/gitlab/ci-network.env`, then converge.

## 1.2.4

**Jobs use the host proxy for the internet. The container config's only default is `NO_PROXY`.** `HTTP_PROXY` and `HTTPS_PROXY` are copied from the host (this shell, then the Docker daemon). If the host set only one, it is used for both. `NSX_HTTP_PROXY` and `NSX_HTTPS_PROXY` still override that.

`NO_PROXY` and `no_proxy` in the runner config are always the same default list: localhost, this host, GitLab, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`. The host's own `NO_PROXY` is not copied into the container. `NSX_NO_PROXY` adds entries on top of that list. Git is no longer told to clear the proxy for the GitLab URL; private addresses stay direct because they are in `NO_PROXY`.

## 1.2.3

**Internal addresses stay off the proxy, in the runner config.** Whenever the runner is given a proxy, its `NO_PROXY` / `no_proxy` now always includes every private range (RFC 1918): `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, plus this host and GitLab. Entries you already set are kept, and a range already listed is not added twice.

That list is part of the registered profile. `scripts/converge.sh` re-registers when it changes, so a later converge cannot put GitLab, NSX, or vCenter back through the corporate proxy. Public hosts (the Terraform registry, Docker Hub) still use the proxy.

## 1.2.2

**Jobs were still failing in a few seconds with exit code 1, all of them, the same way.** That message is what the runner prints when `git fetch` in the helper fails. The job script never starts, so every job looks identical.

The helper was sending the clone to the corporate proxy. `NO_PROXY` on this host lists GitLab's subnet as a CIDR, and the helper's git does not treat a CIDR as a bypass. Git also trusts only the CA file the runner injects, which replaces the system trust store, so a proxy that re-signs TLS fails the clone even when the runner itself stays connected.

Registration now adds a `pre_get_sources_script`. Before fetch it tells git to skip the proxy for this GitLab (an empty `http.<url>.proxy` overrides `HTTPS_PROXY` for that URL) and to trust `CI_SERVER_TLS_CA_FILE`. The profile hash includes that script, so `scripts/converge.sh` re-registers an existing runner.

`scripts/ci-image.sh` no longer clears the image entrypoint while checking `nsx-ci:1`. A tag that is really the Terraform image (`terraform sh` → exit 1) fails the check and is rebuilt.

## 1.2.1

**Jobs were failing in a few seconds with exit code 1, all of them, the same way.** Two separate causes, both fixed:

- The job image's entrypoint was winning. GitLab starts a job with `sh -c`. On the Terraform image that runs `terraform sh`, which exits 1 immediately (`Terraform has no command named "sh"`). Every job now sets an empty entrypoint, so the shell actually runs. This still matters if `nsx-ci:1` on the host is a leftover Terraform image.
- Git clones were trusting only the GitLab CA. The runner itself trusts that CA *and* the host trust store, so it stays connected through a TLS-inspecting proxy. Git in the job does not: `sslCAInfo` replaces the system store. The CA file installed in the runner is now the GitLab CA plus the host bundle, which is what the job's git is given. `scripts/converge.sh` refreshes it on an already-registered runner.

A provider download that fails because the proxy refused it (403, timeout, handshake) is reported as the existing warning (exit 42), not as a hard failure. A constraint that matches no release is still a hard failure.

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
