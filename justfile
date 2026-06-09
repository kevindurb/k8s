default:
  @just --list

get-kubeconfig:
  ssh core@unimatrix-01 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config

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
  kubectl drain --delete-emptydir-data --ignore-daemonsets {{node}}

pre-commit-install:
  pre-commit install
