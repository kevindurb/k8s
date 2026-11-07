# Tasks

## 1. Baseline and manifest change

- [x] 1.1 Update the checkout to `origin/main` before editing, because the local
      checkout is behind the Renovate digest bump. Verify with
      `git fetch origin && git status -sb` that the branch is up to date and
      `grep 'image:' apps/tsgit/deployment.yml` shows the baseline
      `main@sha256:973d24ec…` (build `sha-e381cc147ef7`, the pre-Funnel build).
- [x] 1.2 Change the container image in `apps/tsgit/deployment.yml` to
      `ghcr.io/kevindurb/tsgit:main@sha256:e34206b9c9d94bd61b04ff10886576cf7053fe95c32b321f7ebcf46232bf1641`
      (build `sha-590b7d924fd0`, the newest published `main` build and the only
      one with Funnel). Verify with
      `kustomize build apps/tsgit | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].image'`
      that the rendered image is the new tag-and-digest reference.
- [x] 1.3 Add `TSGIT_FUNNEL: "true"` to the `app` container's environment in
      `apps/tsgit/deployment.yml`, keeping the existing `TZ`, `TSGIT_HOSTNAME` and
      `TS_ADVERTISE_TAGS` entries. Verify with
      `kustomize build apps/tsgit | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env'`
      that `TSGIT_FUNNEL` is present with value `"true"`.
- [x] 1.4 Add a short comment next to the Funnel setting recording its three
      prerequisites (tailnet `funnel` attribute, `cap/funnel` payload under
      `nodeAttrs.app`, HTTPS certificate domain) and that removing the variable
      closes the public listener. Verify `pre-commit run --files apps/tsgit/deployment.yml`
      passes yamllint (document start, 150-character lines).
- [x] 1.5 Validate the change end to end with `kustomize build apps/tsgit`,
      `kustomize build apps` and `just check-kustomize`; all three must succeed,
      and the rendered `apps/tsgit` output must still contain no `Service`, no
      `Ingress`, no `ConfigMap` named `tsgit-gatus`, and no `NetworkPolicy`.

## 2. Preconditions and rollout

- [ ] 2.1 Verify the external Funnel prerequisites are in place before syncing:
      `git -C ../infra fetch origin && git -C ../infra show origin/main:tailnet/policy.hujson`
      shows `tag:tsgit` in `tagOwners`, the `funnel` node attribute for
      `tag:tsgit`, and `github.com/kevindurb/tsgit/cap/funnel` scoped to
      `public/*`; confirm the tailnet has MagicDNS and HTTPS certificates by
      checking the current pod log for an HTTPS line naming
      `tsgit.beaver-cloud.ts.net`. Do not edit the policy from this repo.
- [ ] 2.2 Commit and push the manifest change, then let Argo CD sync the `tsgit`
      Application. Verify `kubectl -n argocd get application tsgit` reports
      `Synced`/`Healthy`, `kubectl -n tsgit rollout status deploy/tsgit-app-deployment`
      completes, and the replacement pod's image is the new digest
      (`kubectl -n tsgit get pod -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'`).
- [ ] 2.3 Verify the running build is Funnel-capable:
      `kubectl -n tsgit exec deploy/tsgit-app-deployment -- tsgit version` reports
      `sha-590b7d924fd0` (not `sha-e381cc147ef7`), and the pod log contains the
      line announcing the public/Funnel listener. If it instead logs a named
      missing prerequisite, confirm the tailnet still serves `https://tsgit/`
      and fix the prerequisite before continuing.
- [ ] 2.4 Confirm the tailnet path is unchanged: from a write-capable tailnet
      identity, clone a repository over `https://tsgit/<namespace>/<repo>.git`
      and confirm the tailnet index still shows the repositories and push
      permissions it showed before the rollout.

## 3. Public surface verification

- [ ] 3.1 From a host outside the tailnet, open `https://tsgit.beaver-cloud.ts.net/`
      and confirm it returns `200` with a filtered index that names no private
      repository. With no `public/*` repository yet, record the empty public
      index as the expected initial state.
- [ ] 3.2 From a write-capable tailnet identity, push a throwaway repository to
      `https://tsgit/public/funnel-smoke.git`, then clone it from outside the
      tailnet with `git clone https://tsgit.beaver-cloud.ts.net/public/funnel-smoke.git`
      and confirm the commit arrives. Delete the throwaway repository afterwards
      with an explicitly scoped `rm -rf /var/lib/tsgit/repos/public/funnel-smoke.git`
      in the pod and confirm the public index no longer lists it.
- [ ] 3.3 Verify the public surface is read-only: from outside the tailnet,
      `git push` to the public clone URL must fail with `404`, and pushing to a
      nonexistent `public/` path must also return `404` without creating a
      repository (check `ls /var/lib/tsgit/repos/public` afterwards).
- [ ] 3.4 Verify the allowlist boundary: create or reuse a repository outside
      `public/` and confirm it returns `404` from the public URL while remaining
      clonable from the tailnet; confirm the public index never names it.

## 4. Rollback and integration checks

- [ ] 4.1 Drill the kill switch: remove `TSGIT_FUNNEL` from the manifest, sync,
      and confirm the public URL no longer serves while the tailnet clone/index
      keep working. Restore the variable and confirm Argo CD returns to
      `Synced`/`Healthy` with the public listener back.
- [ ] 4.2 Run the final repository checks on the completed change:
      `just check-kustomize`, `pre-commit run --files apps/tsgit/deployment.yml`
      and `openspec validate enable-tsgit-funnel --strict` all pass.
