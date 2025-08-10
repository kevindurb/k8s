FROM ghcr.io/ublue-os/ucore-minimal:stable-nvidia

COPY ./files/k3s-selinux-1.6-1.coreos.noarch.rpm /tmp

RUN dnf install -y \
  nfs-utils \
  container-selinux \
  policycoreutils \
  selinux-policy \
  cryptsetup \
  /tmp/k3s-selinux-1.6-1.coreos.noarch.rpm \
  && dnf clean all

RUN dnf --setopt=tsflags=noscripts install -y iscsi-initiator-utils
RUN echo "InitiatorName=$(/sbin/iscsi-iname)" > /etc/iscsi/initiatorname.iscsi

RUN rm /tmp/k3s-selinux-1.6-1.coreos.noarch.rpm

ADD ./files/modules.conf /etc/modules-load.d/k8s.conf
ADD ./files/sysctl.conf /etc/sysctl.d/k8s.conf

RUN mkdir -p /proc && \
    if [ -f /boot/config-$(uname -r) ]; then \
        gzip -c /boot/config-$(uname -r) > /proc/config.gz; \
    elif [ -f /lib/modules/$(uname -r)/config ]; then \
        gzip -c /lib/modules/$(uname -r)/config > /proc/config.gz; \
    fi

RUN dnf remove -y \
  zram-generator-defaults

RUN systemctl disable firewalld \
    && systemctl enable tailscaled \
    && systemctl enable iscsid
