FROM ghcr.io/ublue-os/ucore-minimal:stable-nvidia@sha256:6b1cce1c81fede46163d0fe575d36fb3770282a5bc0ce711116941b0fb65f506

RUN dnf install -y \
  nfs-utils-coreos \
  cryptsetup \
  && dnf clean all

RUN dnf --setopt=tsflags=noscripts install -y iscsi-initiator-utils
RUN echo "InitiatorName=$(/sbin/iscsi-iname)" > /etc/iscsi/initiatorname.iscsi

ADD ./files/modules.conf /etc/modules-load.d/k8s.conf
ADD ./files/sysctl.conf /etc/sysctl.d/k8s.conf

RUN sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

RUN dnf remove -y \
  zram-generator-defaults

RUN systemctl disable firewalld \
    && systemctl enable tailscaled \
    && systemctl enable iscsid
