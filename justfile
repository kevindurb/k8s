default:
  @just --list

get-kubeconfig:
  ssh core@unimatrix-01 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config

tmpl type name:
  #! /usr/bin/env bash
  echo "Creating {{type}}/{{name}}..."
  cp -r apps/template {{type}}/{{name}}

  cd {{type}}/{{name}}
  echo "Updating kustomization.yml..."
  yq -i '.namespace = "{{name}}"' ./kustomization.yml
  yq -i '.namePrefix = "{{name}}-"' ./kustomization.yml
  yq -i '.configMapGenerator[0].files[0] = "{{name}}.yml=gatus.yml"' ./kustomization.yml
  yq -i '.labels[0].pairs["app.kubernetes.io/name"] = "{{name}}"' ./kustomization.yml

  echo "Updating app.yml..."
  yq -i '.metadata.name = "{{name}}"' ./app.yml
  yq -i '.spec.sources[0].path = "{{type}}/{{name}}"' ./app.yml
  yq -i '.spec.destination.namespace = "{{name}}"' ./app.yml

  echo "Updating gatus.yml..."
  yq -i '.endpoints[0].name = "{{name}}"' ./gatus.yml
  yq -i '.endpoints[0].url = "http://{{name}}-app-service.{{name}}"' ./gatus.yml

  echo "Updating deployment.yml..."
  yq -i 'select(.kind == "HTTPRoute").spec.hostnames[0] = "{{name}}.beaver-cloud.xyz"' ./deployment.yml

  cd ..
  echo "Adding to {{type}}/kustomization.yml"
  kustomize edit add resource ./{{name}}/app.yml

  echo "./{{type}}/{{name}}/ Created!"

drain node:
  kubectl drain --delete-emptydir-data --ignore-daemonsets {{node}}

pre-commit-install:
  pre-commit install

check-kustomize:
  find apps platform infrastructure clusters -name "kustomization.y*ml" -execdir kustomize build . > /dev/null \;

check-kustomize-changed *files:
  #!/usr/bin/env bash
  set -euo pipefail

  for file in {{files}}; do
      dir=$(dirname "$file")
      while [[ "$dir" != "." && ! -f "$dir/kustomization.yaml" && ! -f "$dir/kustomization.yml" ]]; do
          dir=$(dirname "$dir")
      done
      echo "$dir"
  done \
  | sort -u \
  | grep -v '^\.$' \
  | while read -r target_dir; do
      echo "🔎 Checking $target_dir..."
      kustomize build "$target_dir" > /dev/null
  done
