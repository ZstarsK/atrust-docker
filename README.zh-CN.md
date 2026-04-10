# atrust-docker

一个用于在 Docker 中运行 ATrust + XFCE 桌面的开源封装项目。

[English README](./README.md)

## 项目说明

这个仓库提供了：

- ATrust + XFCE 的 Docker 镜像构建定义
- 用于启动桌面、代理和守护逻辑的入口脚本
- 一个可直接参考的 Docker Compose 示例

Docker Hub 镜像：

- `zstarsk/atrust-docker:latest`

## 推荐宿主环境

这个项目的原生开发平台是 macOS。

推荐使用的 Docker daemon / runtime：

- macOS 上的 OrbStack

其他 Docker 环境也可能可用，但本项目主要是在 macOS + OrbStack 上开发和验证的。

## 快速开始

### 方式一：使用 Docker Compose

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

启动命令：

```bash
docker compose up -d
```

## 必要运行参数说明

这个镜像不是“拉下来直接无参数运行”的类型，下面这些参数很重要：

- `privileged: true`
- 挂载 `/dev/net/tun`
- 添加 `NET_ADMIN`
- 指定 `linux/amd64`
- 挂载持久化目录保存用户数据和日志

## 环境变量说明

### `GRACE_DESKTOP_SECONDS`

桌面会话在自动关闭逻辑触发前，继续保持可用的时长，单位为秒。

示例默认值：

- `180`

### `WATCHDOG_INTERVAL`

watchdog 检查容器健康状态和相关进程的间隔时间，单位为秒。

示例默认值：

- `5`

### `VPN_TEST_URL`

watchdog 用于做连通性探测的测试 URL。

注意：

- 请改成你自己的可访问地址
- 仓库里故意写成 `xxx`，避免泄露私有内网地址

### `VPN_TEST_TIMEOUT`

连通性测试请求的超时时间，单位为秒。

示例默认值：

- `8`

### `PLUGIN_STRICT_BOOT_SECONDS`

容器启动后，在严格检查阶段持续保证关键 daemon 存活的时间，单位为秒。

示例默认值：

- `180`

## 仓库内容

- `Dockerfile`：镜像构建定义
- `docker-compose.yml`：运行示例配置
- `entrypoint.sh`：启动与 watchdog 逻辑

## 说明

- `entrypoint.sh` 在构建镜像时已经复制进镜像，正常使用时不需要额外挂载
- 如果你需要调整运行行为，优先通过环境变量覆盖
- 正式使用前请先替换掉占位值

## 安全说明

仓库中不包含私有内网地址。实际部署时，请自行填写与你环境匹配的参数。

## License

如果你准备把这个项目更正式地公开发布，建议补充一个明确的 License 文件。
