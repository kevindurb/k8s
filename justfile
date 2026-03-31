default:
  @just --list

get-kubeconfig:
  ssh core@192.168.42.1 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config

argocd-refresh app:
  just kubectl annotate -n argocd application {{app}} argocd.argoproj.io/refresh='normal'

argocd-refresh-all:
  just kubectl get applications -n argocd --no-headers -o custom-columns=":metadata.name" \
    | xargs -I % just argocd-refresh %

argocd-get-initial-admin-password:
  just kubectl get secret -o json -n argocd \
  argocd-initial-admin-secret \
  | jq -r .data.password \
  | base64 --decode

cloudflare-add-route host:
  cloudflared tunnel route dns kube "{{host}}"

kubectl-create-bw-auth-token ns token:
  just kubectl create secret generic bw-auth-token \
    -n {{ns}} --from-literal=token="{{token}}"

kubectl-copy-bw-auth-token to from="default":
  just kubectl-copy-secret {{from}} bw-auth-token {{to}}

kubectl-copy-secret from name to:
   just kubectl -n {{from}} get secret {{name}} -o yaml \
     | yq 'del(.metadata.creationTimestamp, .metadata.uid, .metadata.resourceVersion, .metadata.namespace)' \
     | just kubectl apply --namespace {{to}} -f -

tmpl type name:
  #! /usr/bin/env bash
  cp -r apps/template {{type}}/{{name}}
  mv {{type}}/{{name}}/template.yml {{type}}/{{name}}/{{name}}.yml

  cd {{type}}/{{name}}
  kustomize edit set namespace {{name}}
  kustomize edit set nameprefix {{name}}-

  cd ..
  kustomize edit add resource ./{{name}}/app.yml

  echo "./{{type}}/{{name}}/ Created!

  TODO:
    - [ ] Update app.yml
    - [ ] Update labels in kustomization.yml
    - [ ] Update configMapGenerator for gatus config
    - [ ] Update gatus.yml
  "

drain node:
  just kubectl drain --delete-emptydir-data --ignore-daemonsets {{node}}

brew-exec *args:
  @brew bundle exec "{{args}}"

kubectl *args:
  @just brew-exec kubectl {{args}}

pre-commit-install:
  pre-commit install
