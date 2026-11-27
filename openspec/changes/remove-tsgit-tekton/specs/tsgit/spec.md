# tsgit Specification (delta)

## REMOVED Requirements

### Requirement: Tailnet access and opt-in public Funnel

**Reason**: The tsgit forge is being retired; tailnet-only access is being
replaced by forgejo's tailnet-only ingress and SSH endpoint (see
`add-forgejo-ci`). The public Funnel surface has no equivalent and is going
away entirely; public read access moves to the GitHub push mirror.
**Migration**: Tailnet users clone from `https://forgejo.beaver-cloud.ts.net/...`
or `ssh://forgejo/...`. Public readers use github.com/kevindurb/dotfiles.

### Requirement: Persistent node identity and repository storage

**Reason**: tsgit is deleted; its two PVCs (`tsgit-state`, `tsgit-repos`) are
removed once the `dotfiles` history is verified on forgejo.
**Migration**: Repository data is preserved by pushing full history to forgejo
before deletion; tsgit's state volume is intentionally discarded.

### Requirement: Single active instance

**Reason**: No tsgit pod remains; forgejo enforces its own singleton semantics.
**Migration**: None.

### Requirement: Repository creation on first push

**Reason**: The forge is being replaced; forgejo has no push-to-create
semantics and requires explicit repository creation.
**Migration**: Create repositories in forgejo (UI/API/CLI) before pushing.

### Requirement: Secret handling for node registration

**Reason**: tsgit's Tailscale auth key becomes obsolete with the app.
**Migration**: The `tsgit-auth` SealedSecret is deleted with the app; forgejo
uses OIDC for web sign-in and SSH keys/PATs for git.

### Requirement: Least-privilege runtime

**Reason**: The hardening contract was specific to the tsgit container; it is
meaningless once the workload is gone.
**Migration**: None.

### Requirement: GitOps-managed lifecycle

**Reason**: The `apps/tsgit` Argo CD Application is being deleted (not pruned;
manual removal per the cluster's `prune: false` policy).
**Migration**: `apps/tsgit/` removed from git; the Application removed manually
from the cluster; namespace `tsgit` deleted after verification.

### Requirement: Outbound connectivity only

**Reason**: The tsgit pod no longer exists; the dedicated egress ProxyGroup,
ExternalName Service and CoreDNS rewrite are removed with it.
**Migration**: In-cluster CI access to the forge uses plain ClusterIP DNS
(`forgejo.<namespace>.svc.cluster.local`); the `tag:tekton` grant is removed
from the tailnet policy in `kevindurb/infra`.

### Requirement: Funnel-capable image

**Reason**: Funnel is a tsgit feature; it has no successor.
**Migration**: Public read access is served by the GitHub mirror of published
repositories instead.

### Requirement: Public read-only Funnel surface

**Reason**: See above; the Funnel surface is deleted with the tsgit deployment.
**Migration**: https://github.com/kevindurb/dotfiles (and any other public
mirrors configured in forgejo) replaces the Funnel URLs.

### Requirement: Funnel enablement is explicit and fail-safe

**Reason**: No Funnel, no fail-safe to specify.
**Migration**: None.

### Requirement: Bounded public requests

**Reason**: No public listener remains on the cluster side; GitHub's own
abuse controls apply to the mirror.
**Migration**: None.
