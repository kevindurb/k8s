FROM ghcr.io/ublue-os/ucore-minimal:stable-nvidia

RUN dnf install -y \
  nfs-utils \
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
