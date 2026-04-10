# Use the currently available local base image on this machine.
FROM local/docker-atrust:2.3.10.70-xfce

ARG DEBIAN_FRONTEND=noninteractive

RUN printf '%s\n' \
    'deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware' \
    'deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware' \
    'deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware' \
    > /etc/apt/sources.list \
 && rm -f /etc/apt/sources.list.d/* 2>/dev/null || true

RUN apt-get update && apt-get install -y --no-install-recommends \
    xfce4 xfce4-goodies xrdp xorg xorgxrdp dbus-x11 dbus-user-session \
    x11-xserver-utils procps psmisc sudo iproute2 iptables curl \
    dante-server tinyproxy-bin \
 && rm -rf /var/lib/apt/lists/*

RUN id -u sangfor >/dev/null 2>&1 || useradd -m -s /bin/bash sangfor \
 && echo 'sangfor:sangfor' | chpasswd \
 && adduser xrdp ssl-cert || true \
 && mkdir -p /run/dbus /var/run/dbus /var/log/supervisor

RUN printf 'startxfce4\n' > /etc/skel/.xsession \
 && cp /etc/skel/.xsession /home/sangfor/.xsession \
 && chown sangfor:sangfor /home/sangfor/.xsession \
 && sed -i 's#^exec /bin/sh /etc/X11/Xsession#startxfce4#' /etc/xrdp/startwm.sh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3389 54631 1080 8888
VOLUME ["/root", "/usr/share/sangfor/.aTrust", "/usr/share/sangfor/EasyConnect/resources/logs"]
ENTRYPOINT ["/entrypoint.sh"]
