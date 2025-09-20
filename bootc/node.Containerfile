FROM ghcr.io/ublue-os/ucore-minimal:stable-nvidia@sha256:bcdcd7b296c8153ec9407521472023805dd9169986f93aaf9845d00cd09680d9

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
