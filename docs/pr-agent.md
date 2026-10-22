# PR review bot (PR-Agent)

Status: **added (2026-10-22)**. [PR-Agent](https://github.com/The-PR-Agent/pr-agent) reviews pull requests via `.github/workflows/pr-agent.yml`, calling the Aperture LLM gateway on `ai.beaver-cloud.ts.net` over the tailnet. The runner joins as `tag:pr-agent`, which can reach nothing but Aperture, and Aperture only serves it `deepseek-v4.1-flash`.

## Why two layers of grants

Aperture authorizes by Tailscale identity: on every request it calls `WhoIs` on the remote address and reads that peer's `tailscale.com/cap/aperture` capabilities. So a runner with *network* access to `ai:443` can call any API on it - including `/api/config` - unless the *application* grants are narrowed too.

Aperture combines capabilities from its own configuration with those in the tailnet policy file, and Tailscale grants are additive: a narrow grant never overrides a broad one. Both layers therefore have to be right.

- Tailnet (`tailscale/policy.hujson`): `tag:ai` (the gateway) and `tag:pr-agent` (CI), the network grant `tag:pr-agent -> tag:ai tcp:443`, and the Aperture role/model capabilities.
- Aperture config (on `ai`): providers, connectors and the `pr-agent-daily` quota bucket; its stock `src: ["*"]` grants are **removed**.

## Tailnet changes

Applied by `.github/workflows/tailscale.yml`: `action: test` on the PR, `action: apply` on `main`.

| Source | Destination | Ports | Aperture capability |
| --- | --- | --- | --- |
| `group:ai-users` | `tag:ai` | tcp:443 | `{"role": "user"}`, `{"models": "**"}` |
| `group:ai-admins` | `tag:ai` | tcp:443 | `{"role": "admin"}`, `{"connectors": ["**"]}` |
| `tag:pr-agent` | `tag:ai` | tcp:443 | `{"role": "user", "enable_portal": false}`, `{"models": "*/deepseek-v4.1-flash", "quotas": [{"bucket": "pr-agent-daily"}]}` |

Also in `policy.hujson`:

- `group:ai-users` / `group:ai-admins`, so no grant hardcodes a login name.
- `tag:ai` and `tag:pr-agent` in `tagOwners`, both owned by `group:admins`.
- `nodeAttrs`: `tailscale.com/visible-groups` on `tag:ai`. Aperture cannot resolve `group:` sources without it - grants matching `group:ai-*` silently match nobody, which looks identical to a missing grant (HTTP 403).
- `ssh`: `group:admins -> tag:ai`. Tagging the box converts it from a user-owned device to a tag identity, so the existing `autogroup:self` rule no longer covers it and `tailscale ssh` to `ai` would otherwise fail.
- `tests`: `tag:pr-agent` accepts `tag:ai:443` and denies the app/infra/service tags plus `tag:k8s-node:22`; `tag:ci` is asserted to be denied `tag:ai:443` (the deploy identity must not reach the gateway). No test covers `group:ai-*` on purpose: the ACL tester expands a group to its members, and the only member is an admin with `* -> *`, so any `deny` in that test would fail.

`hosts` stays empty: `tag:ai` replaces any host alias or literal IP, so an IP change or a replacement box needs no policy edit.

## Console steps (once, after the policy is applied)

1. **Machines -> `ai` -> edit tags -> `tag:ai`.** The device stops being `kevindurb@`-owned:

   - `tailscale up` on that box must from now on pass `--advertise-tags=tag:ai`, or the tag is dropped;
   - Taildrop with your own devices no longer includes it;
   - `autogroup:self` no longer matches it (nothing depends on that - `group:admins -> *` still covers you);
   - Serve/cert for `ai.beaver-cloud.ts.net` is unaffected, and key expiry is disabled for tagged devices by default.

2. **Settings -> Trust credentials -> Credential -> OpenID Connect**, and create a dedicated federated identity for this workflow:

   - Issuer: GitHub Actions (`https://token.actions.githubusercontent.com`).
   - Subject: `repo:kevindurb/k8s:*` - this workflow authenticates from three event shapes, so a narrower subject breaks some of them (`pull_request` presents `repo:kevindurb/k8s:pull_request`; `issue_comment` and `workflow_dispatch` present `repo:kevindurb/k8s:ref:refs/heads/main`).
   - Scopes: `auth_keys` (write), nothing else.
   - Tags: `tag:pr-agent` only.
   - Copy the generated **Client ID** and **Audience** into repository secrets `TS_PR_AGENT_OAUTH_ID` and `TS_PR_AGENT_AUDIENCE`.

   A dedicated credential keeps the deploy identity (`tag:ci` -> `svc:argocd`) from being able to mint the review tag. Reusing the shared one also works - add `tag:pr-agent` to *that* credential's tag list and the workflow's `||` fallback to `TS_OAUTH_ID`/`TS_AUDIENCE` picks it up - but then one credential mints both tags.

   If the action fails with `requested tags [tag:pr-agent] are invalid or not permitted`, the credential in use is not the one carrying the tag. That error comes from auth key creation, not from the token exchange, so the console's per-identity error panel does not show it, and propagation is not the cause.

## Aperture config change (on `ai`)

Back up first:

```sh
curl -fsS http://ai.beaver-cloud.ts.net/api/config > aperture-config-backup.json
jq -r '.hash' aperture-config-backup.json
```

Extract the editable configuration, then edit it at `/admin/settings/config` or push it through the API:

```sh
jq -r '.config' aperture-config-backup.json > aperture-config.hujson
```

Changes:

1. **Delete the three stock `"src": ["*"]` grants** (admin role; `role: user` + `models: "**"` + `connectors: "**"`; and the `ollama/*`/`opencode-go/*` pair). They currently make every tailnet device an Aperture admin with every model and every connector. The `connectors: ["**"]` in particular includes the `TailnetSSH` MCP connector, which acts as Aperture's own tailnet identity and would sidestep the `tag:pr-agent -> tag:ai tcp:443` grant entirely.
2. Leave the `kevindurb@github -> connectors: ["TailnetSSH/**"]` grant or drop it; it is redundant now that `group:ai-admins` has `connectors: ["**"]`.
3. Add the quota bucket. Bucket *definitions* live here; only the reference lives in the policy file:

```json
"quotas": {
  "pr-agent-daily": {
    "capacity": "$5.00",
    "rate":     "$2.00/day",
    "on_exceed": "reject",
  },
},
```

### Push via API (optimistic concurrency)

`PUT /api/config` takes the complete HuJSON string plus the current hash; a stale hash is rejected.

```sh
HASH=$(curl -fsS http://ai.beaver-cloud.ts.net/api/config | jq -r '.hash')
jq -n --rawfile config aperture-config.hujson --arg hash "$HASH" '{config: $config, hash: $hash}' \
  | curl -fsS -X PUT http://ai.beaver-cloud.ts.net/api/config \
      -H 'Content-Type: application/json' -d @-
```

### Rollback

```sh
FRESH=$(curl -fsS http://ai.beaver-cloud.ts.net/api/config | jq -r '.hash')
jq -r '.config' aperture-config-backup.json > aperture-config.hujson.orig
jq -n --rawfile config aperture-config.hujson.orig --arg hash "$FRESH" '{config: $config, hash: $hash}' \
  | curl -fsS -X PUT http://ai.beaver-cloud.ts.net/api/config \
      -H 'Content-Type: application/json' -d @-
```

### Ordering (this is what locks you out if done backwards)

1. Merge the policy change. The `*` grants are still in Aperture, so nothing breaks yet.
2. Back up Aperture, remove the `*` grants, add the quota. The `tag:pr-agent` grant in the policy file references the `pr-agent-daily` bucket, so define it here, before the bot's first run, rather than leaving a dangling reference.
3. Verify from your laptop (you are in `group:ai-admins` and `group:ai-users`):

```sh
curl -sS https://ai.beaver-cloud.ts.net/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"ping"}],"max_tokens":8}' \
  -w '\nHTTP %{http_code}\n'
```

`200` means the grants and visible groups resolve. `403` means no `role` grant matched (usually `group:` not resolving - check the nodeAttr and that the groups are applied); `404` means a role matched but no `models` grant. If you are shut out, re-add a temporary `{"src": ["kevindurb@github"], "app": {"tailscale.com/cap/aperture": [{"role": "admin"}]}}` and fix it from the dashboard.

## The workflow

`.github/workflows/pr-agent.yml` triggers on `pull_request` (`opened`, `reopened`, `ready_for_review`, `synchronize`), on `/command` comments in PRs, and on `workflow_dispatch` for smoke tests.

```yaml
      - name: Connect to tailnet
        uses: tailscale/github-action@v4.2.0
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_ID }}
          audience: ${{ secrets.TS_AUDIENCE }}
          tags: tag:pr-agent
          ping: ai
```

The review runs `pragent/pr-agent:0.48.0-github_action`, pinned by digest (`sha256:80edef...9a6d`; Renovate's github-actions manager updates a `docker://` ref), with:

```yaml
          OPENAI__API_BASE: https://ai.beaver-cloud.ts.net/v1
          OPENAI__KEY: aperture-identity   # placeholder: Aperture authorizes by tailnet identity
          config.model: openai/deepseek-v4.1-flash
          config.fallback_models: '[]'
          config.custom_model_max_tokens: "131072"
          github_action_config.auto_review: "true"
          github_action_config.auto_describe: "true"
          github_action_config.auto_improve: "false"
```

There is **no LLM secret**: the `Authorization` header is ignored for shared-key providers, and PR-Agent still needs a non-empty key, hence the placeholder.

The job has `contents: read`, `id-token: write`, `issues: write` and `pull-requests: write`, and performs no checkout, so PR code never executes in the runner.

`workflow_dispatch` joins the tailnet and smoke-tests instead of reviewing:

```sh
tailscale status --json | jq -r '.Self.Tags'        # expect ["tag:pr-agent"]
curl -fsS -o /dev/null https://ai.beaver-cloud.ts.net/v1/models
curl -fsS -o /dev/null https://ai.beaver-cloud.ts.net/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"ping"}],"max_tokens":8}'
```

This is the fastest end-to-end check: it proves the tag is minted, the ACL grant works, and Aperture accepts the tag identity for that one model.

## Attack surface

A pull request from a fork gets no repository secrets **and no OIDC token** from GitHub, so `tailscale/github-action` cannot join the tailnet at all; the job's `if:` on `head.repo.full_name` skips it outright. Even a fork that rewrites this workflow file has nothing to take: no Tailscale credentials, no LLM key, a read-only `GITHUB_TOKEN`, and no checkout to run PR code against.

`issue_comment` runs *do* hold secrets (the workflow comes from the default branch), so they are gated to `OWNER`/`MEMBER`/`COLLABORATOR` on actual PR issues. A stranger cannot start one by commenting on their own PR.

If the credential leaked anyway, the identity is `tag:pr-agent`:

- the ACL `tests` pin it to `tag:ai:443` and deny every other tag and service, so any PR that widens it fails CI;
- Aperture grants it one model, one dollar bucket, no admin role, no connectors and no portal - so it cannot rewrite Aperture's config, read other people's usage, or drive the `TailnetSSH` connector.

That separation is why this bot does not reuse `tag:ci`, which is allowed to reach `svc:argocd` and trigger a deploy.

Residual risks:

- Anyone with push access - or a stolen collaborator/bot token, or a compromised third-party action - is equivalent to the repository owner. That is inherent to credentialed CI; keep the Tailscale action version and the PR-Agent image pinned, and keep `tag:pr-agent` owned by `group:admins` only.
- Prompt injection inside a reviewed diff can steer the wording of the review comment ("this is safe, approve it"). It cannot execute code, change ACLs, or reach Aperture's admin API. Do not give PR-Agent approval authority: `auto_improve` stays off and the job has no `contents: write`.
- Optional extra: repository setting *Actions -> "Require approval for all outside collaborators"*. It does not grant secrets, but it stops drive-by runs and CI-minute spam.
- Do not switch the review job to `pull_request_target` to "support forks": that hands the tailnet credential to PR-triggered runs and defeats everything above.

## Verification

- **2026-10-22, `workflow_dispatch`**: the runner joined as `tag:pr-agent` on the first attempt, `tailscale status --json` reported `["tag:pr-agent"]`, and Aperture answered both `GET /v1/models` and a `deepseek-v4.1-flash` chat completion. The first attempt at this failed with `requested tags [tag:pr-agent] are invalid or not permitted` while the workflow still used the shared `TS_OAUTH_ID` credential; a dedicated federated identity carrying only `tag:pr-agent` fixed it.
- **First real review**: see the comments on this PR.

