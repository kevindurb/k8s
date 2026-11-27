# Tasks

## 1. Manifest change

- [x] 1.1 Add a `repository` section to `gitea.config` in `platform/forgejo/app.yml` with `ENABLE_PUSH_CREATE_USER: "true"`, `ENABLE_PUSH_CREATE_ORG: "true"`, `DEFAULT_PUSH_CREATE_PRIVATE: "true"` (string values, matching the chart's app.ini rendering); verify `kustomize build platform/forgejo` renders cleanly and the diff shows only the three added keys.

## 2. Documentation

- [x] 2.1 Add a short "Push to create" section to `docs/forgejo.md` covering: both keys enabled, private-by-default, the `git push -o repo.private=false` opt-out, and that push-created repos are NOT auto-mirrored to GitHub (mirror is per-repo opt-in); verify the section renders and the commands match the live SSH/HTTPS remotes documented above it.

## 3. Deploy and verify

- [x] 3.1 Merged as PR #658 (squash of `feat/forgejo-push-to-create`, merged 2026-11-27). Argo CD synced `forgejo` (hard refresh), pod rolled (23s old at check), `[repository]` in `app.ini` shows all three keys, `/api/healthz` returns 200. Gatus reported `forgejo` down once during the roll (15:16:31, 10s timeout) and green again from 15:17:22 onward. The PR's `Review` (pr-agent) check failed on an LLM-backend connection error in the action itself; `Check Kustomize` passed and main is not branch-protected.
- [x] 3.2 Verified over SSH: `git push` of a fresh repo to `kevindurb/push-to-create-smoke` created the repo (branch `main`); anonymous HTTPS GET of the repo page returns 404 and `info/refs` 401, i.e. it is private. HTTPS push NOT verified (no non-interactive credential available; skipped per user decision). Scratch repo left in place for the user to delete in the UI.
- [x] 3.3 No organization exists on the instance (anonymous `GET /api/v1/orgs` returns `[]`; user confirmed). The org push-create scenario is untested; `ENABLE_PUSH_CREATE_ORG` remains enabled but unexercised.

## Verification log

- 2026-11-27 ~15:16 UTC: merged PR #658; Argo roll completed; healthz 200; gatus green post-roll.
- 2026-11-27 ~15:3x UTC: SSH push-to-create succeeded; repo confirmed private via anonymous 404/401. HTTPS path skipped at user request. Scratch repo `kevindurb/push-to-create-smoke` pending user deletion.


## Workflow follow-up

- Archive the change once the fix is deployed and verified (spec delta syncs into `openspec/specs/forgejo/spec.md`, carrying the new "Repository creation on first push" requirement).
- Remove the `repo.private=false` verify step's artifacts if any public scratch repos were created during testing (should be none).
