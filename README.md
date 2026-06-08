# atrust-docker

Open source packaging for running ATrust with an XFCE desktop inside Docker.

[中文说明](./README.zh-CN.md)

## Overview

This repository provides:

- A reproducible Docker image definition for ATrust 2.5.16.20 + XFCE
- A container entrypoint for desktop, proxy, and optional watchdog startup
- A Docker Compose example for daily use
- A small `LD_PRELOAD` shim that retries selected `EINTR`-interrupted calls used by aTrust RPC threads
- A login-name fallback preload library used by aTrust plugin startup inside Docker
- A minimal `loginctl` compatibility wrapper for aTrustCore startup in non-systemd containers

Docker Hub images:

- `zstarsk/atrust-docker:latest`
- `zstarsk/atrust-docker:2.5.16.20-xfce`

## Recommended Host Environment

The native development platform for this project is macOS with OrbStack.

Other Docker environments may work, but this project is primarily developed and verified on macOS + OrbStack. The image runs as `linux/amd64`, so Apple Silicon hosts need Docker platform emulation.

## Quick Start

### Docker Compose

```yaml
services:
  atrust-xfce:
    image: zstarsk/atrust-docker:latest
    container_name: atrust-xfce
    platform: linux/amd64
    restart: unless-stopped
    privileged: true
    devices:
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
    sysctls:
      net.ipv4.conf.default.route_localnet: "1"
    environment:
      GRACE_DESKTOP_SECONDS: "180"
      WATCHDOG_INTERVAL: "5"
      VPN_TEST_URL: ""
      VPN_TEST_TIMEOUT: "8"
      PLUGIN_STRICT_BOOT_SECONDS: "180"
      CORE_BOOT_GRACE_SECONDS: "180"
      ATRUST_EINTR_PRELOAD: "1"
    ports:
      - "127.0.0.1:3390:3389"
      - "127.0.0.1:5902:5901"
      - "127.0.0.1:1080:1080"
      - "127.0.0.1:8888:8888"
      - "127.0.0.1:54632:54631"
    volumes:
      - ${HOME}/.atrust-data-xfce/root:/root
      - ${HOME}/.atrust-data-xfce/sangfor-shared:/usr/share/sangfor/.aTrust
      - ${HOME}/.atrust-data-xfce/logs:/usr/share/sangfor/EasyConnect/resources/logs
```

Start the container:

```bash
docker compose up -d
```

Connect to the desktop with RDP:

```text
127.0.0.1:3390
```

The default login user created by the image is:

```text
sangfor / sangfor
```

## Runtime Requirements

This container is not a zero-config image. The following runtime settings are important:

- `privileged: true`
- `/dev/net/tun` device mapping
- `NET_ADMIN` capability
- `platform: linux/amd64`
- Persistent volume mounts for user data and logs

## Environment Variables

### `GRACE_DESKTOP_SECONDS`

How long the desktop session is kept available before automatic shutdown logic runs.

- Default example: `180`
- Set `0`, `never`, `off`, or `disabled` to disable desktop auto-shutdown

### `WATCHDOG_INTERVAL`

How often the watchdog checks local container components, in seconds.

- Default example: `5`
- Set `0`, `off`, or `disabled` to disable the watchdog completely
- When enabled, the watchdog maintains `tinyproxy`, `plugin-daemon`, `danted`, VPN interface changes, and the local SOCKS listener

### `VPN_TEST_URL`

Optional HTTP(S) connectivity test URL used by the watchdog.

- Default: empty
- When empty, the watchdog does not probe any business URL and only maintains local components
- When set, the watchdog runs `curl` inside the container against this URL
- Use a lightweight internal URL in your own environment if you need end-to-end VPN health checks

### `VPN_TEST_TIMEOUT`

Timeout for `VPN_TEST_URL`, in seconds.

- Default example: `8`
- Only used when `VPN_TEST_URL` is not empty

### `PLUGIN_STRICT_BOOT_SECONDS`

How long the container uses stricter boot-time checks to keep the required plugin daemon available for login.

- Default example: `180`
- Set `0` to disable the strict boot window

### `CORE_BOOT_GRACE_SECONDS`

How long the watchdog waits before treating missing aTrustCore readiness ports as restart-worthy.

- Default: `180`
- Keep this long enough for `plugin-daemon` to finish launching aTrustCore during login
- Set `0` to make core readiness checks active immediately after container startup

### `ATRUST_EINTR_PRELOAD`

Controls the bundled `LD_PRELOAD` shim for retrying selected `EINTR`-interrupted aTrust RPC operations.

- Default: `1`
- Set `0`, `off`, or `disabled` to remove it from `/etc/ld.so.preload`

### `EINTR_PRELOAD_LIB`

Path to the preload library used when `ATRUST_EINTR_PRELOAD=1`.

- Default: `/usr/local/lib/eintr-retry.so`

### `CORE_RESTART_INTERVAL`

Minimum interval between aTrustCore readiness-triggered restarts, in seconds.

- Default: `90`

## Build Locally

```bash
docker buildx build \
  --platform linux/amd64 \
  -t zstarsk/atrust-docker:local \
  .
```

The Dockerfile downloads the aTrust 2.5.16.20 Linux installer from Sangfor's public CDN by default. You can override it:

```bash
docker buildx build \
  --platform linux/amd64 \
  --build-arg ATRUST_DEB_URL=https://example.com/aTrustInstaller_amd64.deb \
  -t zstarsk/atrust-docker:local \
  .
```

## Repository Contents

- `Dockerfile`: image build definition
- `bin/loginctl`: minimal session-query compatibility wrapper used inside the image
- `docker-compose.yml`: example runtime configuration
- `entrypoint.sh`: startup, desktop, proxy, and watchdog logic
- `lib/eintr_retry.c`: source for the optional `LD_PRELOAD` shim
- `lib/fake_getlogin.c`: source for the login-name fallback preload used by plugin startup
- `LICENSE`: MIT license

## Security Note

Private internal URLs are not included in this repository. `VPN_TEST_URL` is intentionally empty by default; users should provide their own environment-specific health check URL only when needed.

## License

MIT License
