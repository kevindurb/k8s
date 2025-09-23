FROM ghcr.io/ublue-os/ucore-minimal:stable-nvidia@sha256:1f451d29c06750e491cff3ac4d9dfc2d26b5062b34a316b84f9ffc8b968ce868

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
