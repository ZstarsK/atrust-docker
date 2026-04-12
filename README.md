# atrust-docker

Open source packaging for running ATrust with an XFCE desktop inside Docker.

[中文说明](./README.zh-CN.md)

## Overview

This repository provides:

- A Docker image definition for ATrust + XFCE
- A container entrypoint script for desktop and proxy startup
- A Docker Compose example for daily use

Docker Hub image:

- `zstarsk/atrust-docker:latest`

## Recommended host environment

The native development platform for this project is macOS.

Recommended Docker daemon/runtime:

- OrbStack on macOS

Other Docker environments may also work, but the project is primarily developed and verified on macOS with OrbStack.

## Quick start

### Option 1: Run with Docker Compose

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
      VPN_TEST_URL: "xxx"
      VPN_TEST_TIMEOUT: "8"
      PLUGIN_STRICT_BOOT_SECONDS: "180"
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

## Required runtime settings

This container is not a zero-config image. The following runtime settings are important:

- `privileged: true`
- `/dev/net/tun` device mapping
- `NET_ADMIN` capability
- `linux/amd64` platform
- Persistent volume mounts for user data and logs

## Environment variables

### `GRACE_DESKTOP_SECONDS`

How long the desktop session is kept available before automatic shutdown logic runs.

Default example:

- `180`

### `WATCHDOG_INTERVAL`

How often the watchdog checks container health and related processes, in seconds.

Default example:

- `5`

### `VPN_TEST_URL`

A connectivity test URL used by the watchdog logic.

Important:

- Set this to your own reachable URL
- The repository intentionally uses `xxx` as a placeholder to avoid exposing private internal addresses

### `VPN_TEST_TIMEOUT`

Timeout for the connectivity test request, in seconds.

Default example:

- `8`

### `PLUGIN_STRICT_BOOT_SECONDS`

How long the container keeps strict checks during boot to ensure the required daemon is alive.

Default example:

- `180`

## Repository contents

- `Dockerfile`: image build definition
- `docker-compose.yml`: example runtime configuration
- `entrypoint.sh`: startup and watchdog logic

## Notes

- `entrypoint.sh` is already copied into the image during build, so it does not need to be mounted separately in normal usage
- If you need to customize runtime behavior, prefer overriding environment variables first
- Replace placeholder values before production use

## Security note

Private internal URLs are not included in this repository. Users should provide their own environment-specific values.

## License

MIT License
