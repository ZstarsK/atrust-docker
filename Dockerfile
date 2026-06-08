FROM debian:bookworm-slim AS eintr-builder

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc libc6-dev \
 && rm -rf /var/lib/apt/lists/*

COPY lib/eintr_retry.c lib/fake_getlogin.c /tmp/

# Build a small preload library that makes aTrust RPC reads resilient to EINTR.
RUN gcc -shared -fPIC -O2 -Wall -Wextra -ldl \
    -o /tmp/eintr-retry.so /tmp/eintr_retry.c \
 && gcc -shared -fPIC -O2 -Wall -Wextra \
    -o /tmp/fake-getlogin.so /tmp/fake_getlogin.c

FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG ATRUST_DEB_URL="https://atrustcdn.sangfor.com/standard/linux/2.5.16.20/uos/amd64/aTrustInstaller_amd64.deb"

RUN printf '%s\n' \
    'deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware' \
    'deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware' \
    'deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware' \
    > /etc/apt/sources.list \
 && rm -f /etc/apt/sources.list.d/* 2>/dev/null || true

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates wget curl \
    xfce4 xfce4-goodies xrdp xorg xorgxrdp dbus-x11 dbus-user-session \
    x11-xserver-utils xclip libx11-xcb1 libxtst6 libxss1 libnss3 libasound2 \
    libatk-bridge2.0-0 libgtk-3-0 libgbm1 libqt5x11extras5 \
    libqt5core5a libqt5network5 libqt5widgets5 libldap-2.5-0 \
    libproxy1v5 fonts-wqy-microhei \
    procps psmisc sudo iproute2 iptables socat \
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

RUN set -eux; \
    wget -O /tmp/aTrustInstaller_amd64.deb "$ATRUST_DEB_URL"; \
    dpkg-deb -I /tmp/aTrustInstaller_amd64.deb | sed -n '1,80p'; \
    rm -rf /usr/share/sangfor/aTrust \
           /usr/share/sangfor/EAIO \
           /opt/apps/cn.com.sangfor.atrust \
           /usr/share/applications/cn.com.sangfor.atrust.desktop \
           /usr/share/pixmaps/aTrust.png || true; \
    dpkg-deb -x /tmp/aTrustInstaller_amd64.deb /; \
    rm -f /tmp/aTrustInstaller_amd64.deb; \
    rm -f /usr/share/sangfor/aTrust/resources/lib/libstdc++.so.6* \
          /usr/share/sangfor/aTrust/resources/bin/libstdc++.so.6* \
          /usr/share/sangfor/aTrust/resources/lib/libgcc_s.so* \
          /usr/share/sangfor/aTrust/resources/bin/libgcc_s.so* || true; \
    mkdir -p /usr/share/sangfor/.aTrust/var/run/plugin-daemon \
             /usr/share/sangfor/.aTrust/var/run/plugins/aTrustCore \
             /usr/share/sangfor/.aTrust/var/run/plugins/aTrustTunnel \
             /usr/share/sangfor/.aTrust/database \
             /usr/share/sangfor/.aTrust/iddbase; \
    chmod -R u+rwX,go+rwX /usr/share/sangfor/.aTrust; \
    echo ATRUST > /etc/vpn-type; \
    cat /usr/share/sangfor/aTrust/resources/version

COPY --from=eintr-builder /tmp/eintr-retry.so /usr/local/lib/eintr-retry.so
COPY --from=eintr-builder /tmp/fake-getlogin.so /usr/local/lib/fake-getlogin.so
COPY bin/loginctl /usr/local/bin/loginctl
COPY entrypoint.sh /entrypoint.sh

RUN chmod 0755 /entrypoint.sh \
    /usr/local/bin/loginctl \
    /usr/local/lib/eintr-retry.so \
    /usr/local/lib/fake-getlogin.so

EXPOSE 3389 54631 1080 8888
VOLUME ["/root", "/usr/share/sangfor/.aTrust", "/usr/share/sangfor/EasyConnect/resources/logs"]
ENTRYPOINT ["/entrypoint.sh"]
