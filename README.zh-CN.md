# atrust-docker

一个用于在 Docker 中运行 ATrust + XFCE 桌面的开源封装项目。

[English README](./README.md)

## 项目说明

这个仓库提供：

- ATrust 2.5.16.20 + XFCE 的可复现 Docker 镜像构建定义
- 用于启动桌面、代理和可选 watchdog 的入口脚本
- 一个可直接参考的 Docker Compose 示例
- 一个小型 `LD_PRELOAD` shim，用于重试 aTrust RPC 线程里被 `EINTR` 打断的关键调用

Docker Hub 镜像：

- `zstarsk/atrust-docker:latest`
- `zstarsk/atrust-docker:2.5.16.20-xfce`

## 推荐宿主环境

这个项目的原生开发平台是 macOS + OrbStack。

其他 Docker 环境也可能可用，但本项目主要是在 macOS + OrbStack 上开发和验证。镜像运行平台是 `linux/amd64`，Apple Silicon 宿主需要 Docker 平台模拟。

## 快速开始

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

启动容器：

```bash
docker compose up -d
```

使用 RDP 连接桌面：

```text
127.0.0.1:3390
```

镜像创建的默认登录用户是：

```text
sangfor / sangfor
```

## 必要运行参数

这个镜像不是“拉下来直接无参数运行”的类型，下面这些运行参数很重要：

- `privileged: true`
- 挂载 `/dev/net/tun`
- 添加 `NET_ADMIN`
- 指定 `platform: linux/amd64`
- 挂载持久化目录保存用户数据和日志

## 环境变量

### `GRACE_DESKTOP_SECONDS`

桌面会话在自动关闭逻辑触发前保持可用的时长，单位为秒。

- 示例默认值：`180`
- 设置为 `0`、`never`、`off` 或 `disabled` 可禁用桌面自动关闭

### `WATCHDOG_INTERVAL`

watchdog 检查本地容器组件的间隔时间，单位为秒。

- 示例默认值：`5`
- 设置为 `0`、`off` 或 `disabled` 可完全禁用 watchdog
- 启用时会维护 `tinyproxy`、`plugin-daemon`、`danted`、VPN 网卡变化和本地 SOCKS 监听

### `VPN_TEST_URL`

watchdog 可选的 HTTP(S) 连通性探测 URL。

- 默认值：空
- 为空时，watchdog 不探测任何业务 URL，只维护本地组件
- 配置后，watchdog 会在容器内用 `curl` 访问该 URL
- 如果需要端到端 VPN 健康检查，请填你自己环境里轻量、稳定的内网页面

### `VPN_TEST_TIMEOUT`

`VPN_TEST_URL` 的请求超时时间，单位为秒。

- 示例默认值：`8`
- 仅在 `VPN_TEST_URL` 非空时使用

### `PLUGIN_STRICT_BOOT_SECONDS`

容器启动后的严格检查窗口时长，主要用于登录阶段尽量保证关键 plugin daemon 可用。

- 示例默认值：`180`
- 设置为 `0` 可禁用启动期严格检查窗口

### `ATRUST_EINTR_PRELOAD`

控制内置 `LD_PRELOAD` shim，用于重试 aTrust RPC 操作中被 `EINTR` 打断的部分调用。

- 默认值：`1`
- 设置为 `0`、`off` 或 `disabled` 会从 `/etc/ld.so.preload` 移除该 shim

### `EINTR_PRELOAD_LIB`

`ATRUST_EINTR_PRELOAD=1` 时使用的 preload 库路径。

- 默认值：`/usr/local/lib/eintr-retry.so`

### `CORE_RESTART_INTERVAL`

因 aTrustCore 就绪检查触发重启时，两次重启之间的最小间隔，单位为秒。

- 示例默认值：`90`

## 本地构建

```bash
docker buildx build \
  --platform linux/amd64 \
  -t zstarsk/atrust-docker:local \
  .
```

Dockerfile 默认从深信服公开 CDN 下载 aTrust 2.5.16.20 Linux 安装包。也可以覆盖下载地址：

```bash
docker buildx build \
  --platform linux/amd64 \
  --build-arg ATRUST_DEB_URL=https://example.com/aTrustInstaller_amd64.deb \
  -t zstarsk/atrust-docker:local \
  .
```

## 仓库内容

- `Dockerfile`：镜像构建定义
- `docker-compose.yml`：运行示例配置
- `entrypoint.sh`：启动、桌面、代理和 watchdog 逻辑
- `lib/eintr_retry.c`：可选 `LD_PRELOAD` shim 的源码
- `LICENSE`：MIT 许可证

## 安全说明

仓库中不包含私有内网地址。`VPN_TEST_URL` 默认故意留空；只有需要端到端健康检查时，用户才需要填入自己环境里的探测地址。

## License

MIT License
