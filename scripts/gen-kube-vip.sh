#! /bin/bash

VIP=192.168.42.1
INTERFACE=enp1s0f0
KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r ".[0].name")

kube-vip() {
  docker run --network host --rm "ghcr.io/kube-vip/kube-vip:${KVVERSION}" "$@"
}

kube-vip manifest daemonset \
    --interface $INTERFACE \
    --address $VIP \
    --inCluster \
    --taint \
    --controlplane \
    --arp \
    --leaderElection > ./apps/kube-system/kube-vip/resources/kube-vip.yml
