FROM ghcr.io/ublue-os/ucore-minimal:stable-nvidia

COPY ./files/k3s-selinux-1.6-1.coreos.noarch.rpm /tmp

RUN dnf install -y \
  container-selinux \
  policycoreutils \
  selinux-policy \
  /tmp/k3s-selinux-1.6-1.coreos.noarch.rpm \
  && dnf clean all

RUN rm /tmp/k3s-selinux-1.6-1.coreos.noarch.rpm

ADD ./files/modules.conf /etc/modules-load.d/k8s.conf
ADD ./files/sysctl.conf /etc/sysctl.d/k8s.conf

RUN dnf remove -y \
  zram-generator-defaults

RUN systemctl disable firewalld \
    && systemctl enable tailscaled
