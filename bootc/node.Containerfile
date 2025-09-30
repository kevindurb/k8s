FROM ghcr.io/ublue-os/ucore-minimal:stable-nvidia@sha256:ab879ee71090c161358bb71720d1992cc1ef7097a540ae3f23e98ed194cdb276

RUN dnf install -y \
  nfs-utils-coreos \
  cryptsetup \
  && dnf clean all

RUN dnf --setopt=tsflags=noscripts install -y iscsi-initiator-utils

ADD ./files/modules.conf /etc/modules-load.d/k8s.conf
ADD ./files/sysctl.conf /etc/sysctl.d/k8s.conf

RUN sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

RUN dnf remove -y \
  zram-generator-defaults

RUN systemctl disable firewalld \
    && systemctl enable tailscaled \
    && systemctl enable iscsid
