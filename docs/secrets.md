# Secrets

## Sealed Secrets

Secrets are managed via [sealed secrets](https://github.com/bitnami-labs/sealed-secrets) (`platform/sealed-secrets`): commit `SealedSecret` CRs encrypted with the cluster's private key, and the `sealed-secrets-controller` (chart in `kube-system`, name `sealed-secrets-controller`) unseals them into native k8s `Secret`s that work unchanged with `env[].valueFrom.secretKeyRef` / `envFrom.secretRef`.

Workflow:

1. Create a plain Secret locally (never commit this):

```sh
kubectl create secret generic { NAME } \
  --from-literal={ KEY }='{ VALUE }' -o yaml > { NAME }.secret.yml
```

2. Seal it with the cluster key and write the `SealedSecret`:

```sh
kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller < { NAME }.secret.yml > { NAME }-sealed-secret.yml
rm { NAME }.secret.yml
```

To migrate an existing in-cluster `Secret` without ever writing plaintext to disk:

```sh
kubectl -n { NS } get secret { NAME } -o yaml \
  | yq 'del(.metadata.ownerReferences, .metadata.uid, .metadata.resourceVersion,
            .metadata.creationTimestamp, .metadata.managedFields,
            .metadata.labels, .metadata.annotations)' \
  | kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller -o yaml \
  > { NAME }-sealed-secret.yml
```

3. Commit the `SealedSecret` (see `apps/linkding/tsidp-sealed-secret.yml` for an example) and reference the generated `Secret` by name as usual.

### Naming vs. kustomize `namePrefix`

The unsealed `Secret` is always named after the `SealedSecret`'s own `metadata.name` (`spec.template.metadata.name` is ignored), and sealed-secrets' default *strict* scope binds the ciphertext to that exact name + namespace. Every app sets `namePrefix: <app>-`, which kustomize applies to the `SealedSecret` name too, and kustomize does **not** rewrite `SealedSecret` references.

So the `SealedSecret`'s `metadata.name`, after the `namePrefix` is applied, must equal the name the app references:

- If the target name already starts with the prefix, use only the un-prefixed part: `metadata.name: secret` → `healthchecks-secret`.
- Otherwise the unsealed name becomes `<app>-<metadata.name>`, and the references must be updated to match: miniflux `postgres-secret` → `miniflux-postgres-secret`.

Seal with the **final (post-prefix) name**. When an existing in-cluster Secret's name differs from the final name, rename it while sealing (add `| yq '.metadata.name = "<final>"'` before `kubeseal`). `kubeseal --validate` reads the raw file, so validate against the post-prefix name: `yq '.metadata.name = "<final>"' { NAME }-sealed-secret.yml | kubeseal --validate`.

The controller's private key is the root of trust — back it up after installing or rekeying:

```sh
just -f platform/sealed-secrets/justfile export-secrets
```

**Never commit raw secret values — only `SealedSecret` encrypted data.**
