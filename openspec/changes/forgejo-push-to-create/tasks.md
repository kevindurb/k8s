# Tasks

## 1. Manifest change

- [x] 1.1 Add a `repository` section to `gitea.config` in `platform/forgejo/app.yml` with `ENABLE_PUSH_CREATE_USER: "true"`, `ENABLE_PUSH_CREATE_ORG: "true"`, `DEFAULT_PUSH_CREATE_PRIVATE: "true"` (string values, matching the chart's app.ini rendering); verify `kustomize build platform/forgejo` renders cleanly and the diff shows only the three added keys.

## 2. Documentation

- [x] 2.1 Add a short "Push to create" section to `docs/forgejo.md` covering: both keys enabled, private-by-default, the `git push -o repo.private=false` opt-out, and that push-created repos are NOT auto-mirrored to GitHub (mirror is per-repo opt-in); verify the section renders and the commands match the live SSH/HTTPS remotes documented above it.

## 3. Deploy and verify

- [ ] 3.1 Commit and merge the above (Argo CD syncs `platform/forgejo`); verify the forgejo pod rolls and `https://forgejo.beaver-cloud.ts.net/api/healthz` is green and Gatus stays green.
- [ ] 3.2 Push a scratch repo to a nonexistent path over SSH (e.g. `git push ssh://git@forgejo-ssh.beaver-cloud.ts.net/kevindurb/push-to-create-smoke.git`) and verify it is created and private in the UI; delete the scratch repo; repeat once over HTTPS; record results in the change notes.
- [ ] 3.3 Check whether an org exists on the instance (`forgejo` admin UI or `kubectl exec -n forgejo deploy/forgejo -- forgejo ...`); if one does, push-create a scratch org repo and verify it lands private, then delete it; if no org exists, note the org scenario as untested (design.md).

## Workflow follow-up

- Archive the change once the fix is deployed and verified (spec delta syncs into `openspec/specs/forgejo/spec.md`, carrying the new "Repository creation on first push" requirement).
- Remove the `repo.private=false` verify step's artifacts if any public scratch repos were created during testing (should be none).
