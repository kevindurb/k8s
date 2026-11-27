# Spec Delta

## ADDED Requirements

### Requirement: The runner VM is a Tailscale device tagged `tag:ci`

The runner VM SHALL join the tailnet on every boot using a reusable,
pre-authorized, ephemeral auth key that carries the `tag:ci` tag. The key
SHALL come from a `SealedSecret` in the cluster and SHALL NOT be baked into
the image or committed in plaintext. The tailnet device entry SHALL be
ephemeral so VM recreation does not accumulate stale devices, and
re-creation SHALL require no manual tailnet administration.

#### Scenario: Fresh VM joins on boot
- **WHEN** the VM boots (first boot or recreation from a new image pin)
- **THEN** it registers with MagicDNS as `ci-runner` tagged `tag:ci` within a few minutes and `tailscale status` on the host shows it connected
- **AND** no plaintext key exists anywhere outside the sealed secret

#### Scenario: Ephemeral device hygiene
- **WHEN** the VM is recreated from a new `ci-runner-disk` tag
- **THEN** the previous device entry expires automatically and the new VM re-joins without human intervention in the tailnet admin console

### Requirement: The VM reaches forgejo through its own tailnet identity

The VM SHALL resolve and reach `forgejo.beaver-cloud.ts.net` over the tailnet as `tag:ci`, granted `tag:apps:443` in the tailnet policy. It SHALL NOT depend on the LAN router hairpin (`tag:router`) or on node-originated forwarding for its CI traffic.

#### Scenario: Runner polls forgejo over the tailnet
- **WHEN** the runner dials `https://forgejo.beaver-cloud.ts.net`
- **THEN** the connection is carried by the VM's tailnet interface, sourced from `tag:ci`, and authorized by an explicit `tag:ci → tag:apps:443` grant

#### Scenario: Router path is no longer required
- **WHEN** the LAN router stops forwarding CGNAT destinations
- **THEN** the runner's reachability to forgejo is unaffected

### Requirement: The runner has the same tailnet grants as GitHub Actions CI

`tag:ci` SHALL authorize the VM to reach Aperture (`tag:ai:443`, `ci-agents` bucket, `deepseek`-class models), tsgit (`tag:tsgit:443`, read, `cap/repo`), and Argo CD (`svc:argocd:443`). No additional per-service plumbing is required in the VM image for these.

#### Scenario: A CI job calls Aperture
- **WHEN** a job in the runner calls the Aperture gateway with `tag:ci` credentials
- **THEN** it receives the same `ci-agents` quota treatment as a GitHub Actions runner

### Requirement: Inbound access is Tailscale SSH for admins only

The VM SHALL run `tailscaled` with SSH enabled. The tailnet policy SHALL grant `group:admins` SSH access to `tag:ci` (users `root` and `autogroup:nonroot`). No other inbound access to the VM SHALL be granted, and no SSH path via the LAN/router SHALL be relied on.

#### Scenario: Admin SSHes to the runner
- **WHEN** a `group:admins` member runs `ssh root@ci-runner` (with Tailscale SSH enabled)
- **THEN** access is granted per the tailnet SSH policy without any VM-side sshd password or extra keys

#### Scenario: Non-admin has no inbound path
- **WHEN** a non-admin tailnet member attempts to SSH to `ci-runner`
- **THEN** the Tailscale SSH policy denies it

### Requirement: MagicDNS resolution inside the VM

The VM SHALL run with MagicDNS enabled (`accept-dns`), resolving `*.beaver-cloud.ts.net` names to tailnet addresses inside the VM. LAN DNS answers are not required for the runner's tailnet traffic.

#### Scenario: VM resolves a tailnet name
- **WHEN** a job resolves `forgejo.beaver-cloud.ts.net` inside the VM
- **THEN** it gets the tailnet VIP, not an answer from the LAN resolver
