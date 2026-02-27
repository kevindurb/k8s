default:
  just --list

get-kubeconfig:
  ssh core@192.168.42.1 'sudo cat /etc/rancher/k3s/k3s.yaml' > kubeconfig

argocd-refresh app:
  kubectl annotate -n argocd application {{app}} argocd.argoproj.io/refresh='normal'

argocd-refresh-all:
  kubectl get applications -n argocd --no-headers -o custom-columns=":metadata.name" \
    | xargs -I % just argocd-refresh %

argocd-get-initial-admin-password:
  kubectl get secret -o json -n argocd \
  argocd-initial-admin-secret \
  | jq -r .data.password \
  | base64 --decode

cloudflare-add-route host:
  cloudflared tunnel route dns kube "{{host}}"

kubectl-create-bw-auth-token ns token:
  kubectl create secret generic bw-auth-token \
    -n {{ns}} --from-literal=token="{{token}}"

kubectl-copy-bw-auth-token to from="default":
  just kubectl-copy-secret {{from}} bw-auth-token {{to}}

kubectl-copy-secret from name to:
   kubectl -n {{from}} get secret {{name}} -o yaml \
     | yq 'del(.metadata.creationTimestamp, .metadata.uid, .metadata.resourceVersion, .metadata.namespace)' \
     | kubectl apply --namespace {{to}} -f -

