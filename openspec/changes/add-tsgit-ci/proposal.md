# Proposal

## Why

`tsgit` is the canonical host for the owner's git repositories (currently `kevindurb/dotfiles` and `kevindurb/ci`), but it has no CI story: it cannot run pipelines, cannot receive webhooks, and there is no trigger for builds after a push. The `ci` repo sketched a hand-rolled `nq`/post-receive design that cannot work against tsgit at all, because tsgit runs no server-side hooks. The result is that pushes to tsgit-hosted repos are never automatically validated, while the rest of the homelab (GitHub-hosted repos) gets full CI and GitOps CD already.

Now is the right time because `dotfiles` is the first tsgit-hosted repo that benefits (template-render and shell checks on every push), and every future tsgit repo will need the same scaffold.

## What Changes

- Add a Tekton Pipelines installation to the cluster (GitOps-managed, Argo CD app), with the Tekton Dashboard exposed tailnet-only via the Tailscale ingress.
- Add an egress path so in-cluster workloads can reach the tsgit tailnet service anonymously as a tagged identity: a new egress ProxyGroup (tag proposed `tag:tekton`), an ExternalName Service, and a CoreDNS rewrite entry — the same pattern already used for `ai` and `idp`. The matching tailnet-policy grant (read-only `cap/repo` for `tag:tekton`) lives in the `kevindurb/infra` repo and is a prerequisite, not part of this change.
- Add a small custom "poller" (CronJob) that watches the configured tsgit repos via `git ls-remote`, detects new commit SHAs, and creates a `PipelineRun` per changed ref. tsgit offers no webhooks, so polling is the only trigger; Pipelines-as-Code is therefore not usable.
- Add a pod template / Task for validating the `dotfiles` repository (chezmoi template render + shellcheck of shell scripts) and wire `dotfiles@main` as the first polled repo.
- No CD in this change, no notifications, no commit-status feedback into tsgit (it has no status API). Green/red is observed via the Tekton Dashboard / `tkn`.

## Capabilities

### New Capabilities
- `tsgit-ci`: continuous integration for repositories hosted on the tsgit forge — how pipelines get triggered (polling, since tsgit lacks webhooks), how pods authenticate to tsgit (tailnet egress identity, no git credentials), how builds are isolated, and how results are surfaced.

### Modified Capabilities
- None.

## Impact

- New Argo CD applications under a new app directory (e.g. `apps/tekton/` or `infrastructure/tekton/`) for Pipelines + Dashboard; a new `infrastructure/` (or shared) manifest set for the egress ProxyGroup + ExternalName Service; a one-line CoreDNS rewrite addition.
- New `tailnet policy` grant in `kevindurb/infra` (outside this repo) — prerequisite, coordinated separately.
- New secrets: none required for v1 (anonymous read via the egress tag; no registry pushes, no webhooks).
- Resource footprint: Tekton controllers + webhook (~a few hundred MB), plus per-build pods on demand; Dashboard is lightweight.
- Repos gain pipelines only when their names/SHAs are registered with the poller; `dotfiles` is the first.
- tsgit itself is unchanged. The `ci` repo sketch (post-receive + nq) is superseded as an approach; no decision is made here about deleting it later.
