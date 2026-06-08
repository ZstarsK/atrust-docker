#!/bin/bash
set -Eeuo pipefail

# =========================
# Config
# =========================
SANGFOR_USER="${SANGFOR_USER:-sangfor}"
GRACE_DESKTOP_SECONDS="${GRACE_DESKTOP_SECONDS:-180}"   # 3分钟后关闭 xrdp
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-5}"
VPN_TEST_URL="${VPN_TEST_URL:-}"
VPN_TEST_TIMEOUT="${VPN_TEST_TIMEOUT:-8}"
PLUGIN_STRICT_BOOT_SECONDS="${PLUGIN_STRICT_BOOT_SECONDS:-180}"  # 启动前3分钟严格保证 daemon 存在，便于登录
CORE_RESTART_INTERVAL="${CORE_RESTART_INTERVAL:-90}"
ATRUST_EINTR_PRELOAD="${ATRUST_EINTR_PRELOAD:-1}"
EINTR_PRELOAD_LIB="${EINTR_PRELOAD_LIB:-/usr/local/lib/eintr-retry.so}"

LOG_DIR="${LOG_DIR:-/tmp}"
PLUGIN_LOG="${LOG_DIR}/atrust-plugin-daemon.log"
TINYPROXY_LOG="${LOG_DIR}/tinyproxy.log"
DANTED_LOG="${LOG_DIR}/danted.log"
WATCHDOG_LOG="${LOG_DIR}/watchdog.log"
XRDP_LOG="${LOG_DIR}/xrdp.stdout.log"
SESMAN_LOG="${LOG_DIR}/xrdp-sesman.stdout.log"

START_TS="$(date +%s)"

PLUGIN_PID=""
XRDP_PID=""
SESMAN_PID=""
DANTED_PID=""
TINYPROXY_PID=""
WATCHDOG_PID=""
DESKTOP_TIMER_PID=""
KEEPALIVE_PID=""
DANTED_IF=""
LAST_CORE_RESTART_TS=0

# =========================
# Common utils
# =========================
log() {
  local msg="$*"
  echo "[$(date '+%F %T')] $msg" | tee -a "$WATCHDOG_LOG" >/dev/null
}

get_uid() {
  id -u "$SANGFOR_USER"
}

get_runtime_dir() {
  echo "/run/user/$(get_uid)"
}

get_session_bus() {
  echo "unix:path=$(get_runtime_dir)/bus"
}

cleanup_pid() {
  
  local pid="${1:-}"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1

    kill -9 "$pid" 2>/dev/null || true
  fi
}

cleanup() {
  cleanup_pid "${DESKTOP_TIMER_PID:-}"
  cleanup_pid "${WATCHDOG_PID:-}"
  cleanup_pid "${KEEPALIVE_PID:-}"
  cleanup_pid "${DANTED_PID:-}"
  cleanup_pid "${TINYPROXY_PID:-}"
  cleanup_pid "${PLUGIN_PID:-}"
  cleanup_pid "${XRDP_PID:-}"
  cleanup_pid "${SESMAN_PID:-}"
}
trap cleanup EXIT INT TERM

ensure_dirs() {
  local uid runtime_dir
  uid="$(get_uid)"
  runtime_dir="$(get_runtime_dir)"

  mkdir -p \
    /run/dbus /var/run/dbus \
    "$runtime_dir" \
    /run/xrdp /run/xrdp/sockdir /var/run/xrdp \
    /run/tinyproxy \
    /usr/share/sangfor/.aTrust/var/run/plugin-daemon \
    /usr/share/sangfor/.aTrust/var/run/plugins/aTrustCore \
    /usr/share/sangfor/.aTrust/var/run/plugins/aTrustTunnel

  chown "$SANGFOR_USER:$SANGFOR_USER" "$runtime_dir" || true
  chmod 700 "$runtime_dir" || true
  chmod 1777 /run/xrdp/sockdir || true

  touch "$PLUGIN_LOG" "$TINYPROXY_LOG" "$DANTED_LOG" "$WATCHDOG_LOG" "$XRDP_LOG" "$SESMAN_LOG"

  rm -f /var/run/dbus/pid /run/dbus/pid || true
  rm -f /var/run/xrdp/xrdp.pid /var/run/xrdp/xrdp-sesman.pid /run/xrdp/xrdp.pid /run/xrdp/xrdp-sesman.pid || true
  rm -f /run/tinyproxy/tinyproxy.pid /var/run/tinyproxy/tinyproxy.pid || true
}

ensure_localhost_sangfor_host() {
  local host_name hosts_file tmp_file
  host_name="localhost.sangfor.com.cn"
  hosts_file="/etc/hosts"

  # aTrust 的本地管理接口依赖该域名命中容器内回环地址，避免被 DNS/TUN 解析成 fake-ip。
  if getent hosts "$host_name" 2>/dev/null | awk '{print $1}' | grep -qx '127.0.0.1'; then
    return 0
  fi

  tmp_file="$(mktemp)"
  awk -v host_name="$host_name" '
    $0 !~ ("(^|[[:space:]])" host_name "([[:space:]]|$)") { print }
    END { print "127.0.0.1 " host_name }
  ' "$hosts_file" > "$tmp_file"
  cat "$tmp_file" > "$hosts_file"
  rm -f "$tmp_file"
}

configure_eintr_preload() {
  local preload_file tmp_file
  preload_file="/etc/ld.so.preload"

  case "$ATRUST_EINTR_PRELOAD" in
    1|true|TRUE|yes|YES|on|ON)
      if [ ! -r "$EINTR_PRELOAD_LIB" ]; then
        log "EINTR preload requested but library is missing: $EINTR_PRELOAD_LIB"
        return 0
      fi

      if ! LD_PRELOAD="$EINTR_PRELOAD_LIB" /bin/true >/dev/null 2>&1; then
        log "EINTR preload library failed validation: $EINTR_PRELOAD_LIB"
        return 0
      fi

      # aTrust 的 RPC 线程会被 SIGCHLD 打断；预加载 shim 负责重试 EINTR 并阻断监听 fd 继承。
      touch "$preload_file"
      if ! grep -Fxq "$EINTR_PRELOAD_LIB" "$preload_file" 2>/dev/null; then
        tmp_file="$(mktemp)"
        awk -v lib="$EINTR_PRELOAD_LIB" '$0 != lib { print }' "$preload_file" > "$tmp_file"
        printf '%s\n' "$EINTR_PRELOAD_LIB" >> "$tmp_file"
        cp "$tmp_file" "$preload_file"
        rm -f "$tmp_file"
      fi

      log "EINTR preload enabled: $EINTR_PRELOAD_LIB"
      ;;
    *)
      if [ -f "$preload_file" ]; then
        tmp_file="$(mktemp)"
        awk -v lib="$EINTR_PRELOAD_LIB" '$0 != lib { print }' "$preload_file" > "$tmp_file"
        cp "$tmp_file" "$preload_file"
        rm -f "$tmp_file"
      fi

      log "EINTR preload disabled"
      ;;
  esac
}

ensure_dbus() {
  local runtime_dir session_bus
  runtime_dir="$(get_runtime_dir)"
  session_bus="$(get_session_bus)"

  if [ ! -S /run/dbus/system_bus_socket ]; then
    log "starting system dbus"
    dbus-daemon --system --fork
  fi

  if ! su -s /bin/sh "$SANGFOR_USER" -c "export XDG_RUNTIME_DIR=$runtime_dir; test -S $runtime_dir/bus"; then
    log "starting session dbus for $SANGFOR_USER"
    su -s /bin/sh "$SANGFOR_USER" -c "export XDG_RUNTIME_DIR=$runtime_dir; dbus-daemon --session --address=$session_bus --fork"
  fi

  export XDG_RUNTIME_DIR="$runtime_dir"
  export DBUS_SESSION_BUS_ADDRESS="$session_bus"

  cat > /etc/profile.d/atrust-env.sh <<ENV
export XDG_RUNTIME_DIR=$runtime_dir
export DBUS_SESSION_BUS_ADDRESS=$session_bus
ENV
}

write_tinyproxy_conf() {
  cat > /etc/tinyproxy.conf <<'EOF'
User nobody
Group nogroup
Port 8888
Listen 0.0.0.0
Timeout 600
DefaultErrorFile "/usr/share/tinyproxy/default.html"
StatFile "/usr/share/tinyproxy/stats.html"
LogLevel Info
PidFile "/run/tinyproxy/tinyproxy.pid"
MaxClients 100
Allow 127.0.0.1
Allow 0.0.0.0/0
ViaProxyName "atrust-xfce"
DisableViaHeader Yes
EOF
}

plugin_port_file() {
  echo "/usr/share/sangfor/.aTrust/var/run/plugin-daemon/thrift"
}

plugin_port() {
  local f
  f="$(plugin_port_file)"
  [ -f "$f" ] && cat "$f" 2>/dev/null || true
}

is_port_listening() {
  local port="${1:-}"
  [ -n "$port" ] || return 1
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"
}

plugin_alive() {
  if [ -n "${PLUGIN_PID:-}" ] && kill -0 "$PLUGIN_PID" 2>/dev/null; then
    return 0
  fi

  local pid
  pid="$(pgrep -f '/usr/share/sangfor/aTrust/resources/bin/aTrustAgent --plugin plugin-daemon --plugin-cmd \|' | head -n1 || true)"
  if [ -n "$pid" ]; then
    PLUGIN_PID="$pid"
    return 0
  fi

  return 1
}

plugin_port_candidates() {
  local file_port
  file_port="$(plugin_port)"
  printf '%s\n' "$file_port" 54631 56641 58641 | awk 'NF && !seen[$0]++'
}

plugin_ready() {
  local port
  plugin_alive || return 1

  while IFS= read -r port; do
    [ -n "$port" ] || continue
    if is_port_listening "$port"; then
      return 0
    fi
  done < <(plugin_port_candidates)

  return 1
}

core_port_file() {
  echo "/usr/share/sangfor/.aTrust/var/run/httpserver"
}

core_port() {
  local f file_port
  f="$(core_port_file)"
  file_port="$([ -f "$f" ] && cat "$f" 2>/dev/null || true)"
  printf '%s\n' "$file_port" 54630 54631 | awk 'NF && !seen[$0]++'
}

core_alive() {
  pgrep -f '/usr/share/sangfor/aTrust/resources/bin/aTrustAgent --plugin plugins/aTrustCore --enable-http --enable-event-center' >/dev/null 2>&1
}

core_ready() {
  local port
  core_alive || return 1

  while IFS= read -r port; do
    [ -n "$port" ] || continue
    if is_port_listening "$port"; then
      return 0
    fi
  done < <(core_port)

  return 1
}

restart_core_if_stuck() {
  local now pid port
  core_ready && return 0

  now="$(date +%s)"
  if [ $((now - LAST_CORE_RESTART_TS)) -lt "$CORE_RESTART_INTERVAL" ]; then
    return 1
  fi

  port="$(core_port | paste -sd, -)"
  log "aTrustCore not ready (port=${port:-none}), restarting core process"
  LAST_CORE_RESTART_TS="$now"

  pid="$(pgrep -f '/usr/share/sangfor/aTrust/resources/bin/aTrustAgent --plugin plugins/aTrustCore --enable-http --enable-event-center' | head -n1 || true)"
  cleanup_pid "$pid"
  return 1
}

start_plugin_daemon() {
  log "starting plugin-daemon"
  rm -f \
    /usr/share/sangfor/.aTrust/var/run/aTrustDaemon-* \
    /usr/share/sangfor/.aTrust/var/run/plugin-daemon/thrift \
    /root/.aTrust/var/run/plugin-daemon/thrift 2>/dev/null || true

  FAKE_LOGIN="$SANGFOR_USER" \
  LD_PRELOAD=/usr/local/lib/fake-getlogin.so \
  LD_LIBRARY_PATH="/usr/share/sangfor/aTrust:/usr/share/sangfor/aTrust/resources/bin:${LD_LIBRARY_PATH:-}" \
    /usr/share/sangfor/aTrust/resources/bin/aTrustAgent \
      --plugin plugin-daemon --plugin-cmd '|' >>"$PLUGIN_LOG" 2>&1 &

  PLUGIN_PID=$!
}

restart_plugin_daemon() {
  log "restarting plugin-daemon"
  cleanup_pid "${PLUGIN_PID:-}"
  start_plugin_daemon
}

start_tinyproxy() {
  log "starting tinyproxy"
  pkill -x tinyproxy 2>/dev/null || true
  sleep 1
  tinyproxy -d -c /etc/tinyproxy.conf >>"$TINYPROXY_LOG" 2>&1 &
  TINYPROXY_PID=$!
}

tinyproxy_ready() {
  [ -n "${TINYPROXY_PID:-}" ] && kill -0 "$TINYPROXY_PID" 2>/dev/null && is_port_listening 8888
}

find_vpn_if() {
  ip -o link 2>/dev/null | awk -F': ' '$2 ~ /^(utun[0-9]+|tun[0-9]+|tap[0-9]+|sdpvnic[0-9]*|sangforvnic[0-9]*)$/ {print $2}'
}

start_danted() {
  local vpn_if="${1:-}"
  [ -n "$vpn_if" ] || return 1

  log "starting danted on $vpn_if"

  cat > /run/danted.conf <<EOF
logoutput: $DANTED_LOG
user.privileged: root
user.unprivileged: nobody
user.libwrap: nobody
internal: 0.0.0.0 port = 1080
external: ${vpn_if}
socksmethod: none
clientmethod: none
timeout.connect: 30
timeout.io: 600
client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect disconnect error
}
pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp udp
  log: connect disconnect error
}
EOF

  pkill -x danted 2>/dev/null || true
  sleep 1
  /usr/sbin/danted -D -f /run/danted.conf
  DANTED_PID="$(pgrep -x danted | tail -n1 || true)"
}

danted_alive() {
  if [ -n "${DANTED_PID:-}" ] && kill -0 "$DANTED_PID" 2>/dev/null; then
    return 0
  fi

  local pid
  pid="$(pgrep -x danted | head -n1 || true)"
  if [ -n "$pid" ]; then
    DANTED_PID="$pid"
    return 0
  fi

  return 1
}

danted_ready() {
  danted_alive && is_port_listening 1080
}

vpn_http_check_enabled() {
  [ -n "$VPN_TEST_URL" ]
}

vpn_http_ok() {
  vpn_http_check_enabled || return 0

  curl -fsS \
    --max-time "$VPN_TEST_TIMEOUT" \
    "$VPN_TEST_URL" >/dev/null 2>&1
}

desktop_running() {
  kill -0 "${SESMAN_PID:-0}" 2>/dev/null && kill -0 "${XRDP_PID:-0}" 2>/dev/null
}

start_xrdp() {
  log "starting xrdp services"
  /usr/sbin/xrdp-sesman --nodaemon >>"$SESMAN_LOG" 2>&1 &
  SESMAN_PID=$!
  /usr/sbin/xrdp --nodaemon >>"$XRDP_LOG" 2>&1 &
  XRDP_PID=$!
}

gui_log() {
  echo "[$(date '+%F %T')] $*" >> /tmp/cleanup-gui.log
}

kill_tree_term() {
  local pid="$1"
  local children child

  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || return 0

  children="$(pgrep -P "$pid" || true)"
  for child in $children; do
    kill_tree_term "$child"
  done

  kill -TERM "$pid" 2>/dev/null || true
}

kill_tree_kill() {
  local pid="$1"
  local children child

  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || return 0

  children="$(pgrep -P "$pid" || true)"
  for child in $children; do
    kill_tree_kill "$child"
  done

  kill -KILL "$pid" 2>/dev/null || true
}

stop_graphical_stack() {
  gui_log "===== stop_graphical_stack start ====="

  # 1) 先找 xrdp-sesman 的“会话子进程”
  # 你当前树里是：
  # 157(root) xrdp-sesman master
  # └─ 234(root) xrdp-sesman session child
  #
  # 这里不写死 234，而是动态找 master(157) 的直接子进程
  local sesman_master sesman_children pid

  sesman_master="$(pgrep -xo xrdp-sesman || true)"
  if [ -n "$sesman_master" ]; then
    gui_log "found xrdp-sesman master pid=$sesman_master"
    sesman_children="$(pgrep -P "$sesman_master" || true)"

    for pid in $sesman_children; do
      gui_log "TERM xrdp session tree root pid=$pid"
      kill_tree_term "$pid"
    done

    sleep 3

    for pid in $sesman_children; do
      if kill -0 "$pid" 2>/dev/null; then
        gui_log "KILL xrdp session tree root pid=$pid"
        kill_tree_kill "$pid"
      fi
    done
  else
    gui_log "xrdp-sesman master not found"
  fi

  # 2) 清 sangfor 用户下残留的 aTrustTray GUI
  # 只杀 GUI，不碰 aTrustCore / Xtunnel / plugin-daemon
  local tray_pids
  tray_pids="$(pgrep -u "$SANGFOR_USER" -f '/usr/share/sangfor/aTrust/aTrustTray' || true)"
  if [ -n "$tray_pids" ]; then
    gui_log "TERM aTrustTray pids: $tray_pids"
    for pid in $tray_pids; do
      kill -TERM "$pid" 2>/dev/null || true
    done

    sleep 2

    tray_pids="$(pgrep -u "$SANGFOR_USER" -f '/usr/share/sangfor/aTrust/aTrustTray' || true)"
    if [ -n "$tray_pids" ]; then
      gui_log "KILL aTrustTray pids: $tray_pids"
      for pid in $tray_pids; do
        kill -KILL "$pid" 2>/dev/null || true
      done
    fi
  fi

  # 3) 再清理一些桌面残留（只清 GUI 相关）
  pkill -TERM -u "$SANGFOR_USER" -x xrdp-chansrv 2>/dev/null || true
  pkill -TERM -u "$SANGFOR_USER" -x xfce4-session 2>/dev/null || true
  pkill -TERM -u "$SANGFOR_USER" -x xfce4-panel 2>/dev/null || true
  pkill -TERM -u "$SANGFOR_USER" -x xfce4-notifyd 2>/dev/null || true
  pkill -TERM -u "$SANGFOR_USER" -x Xorg 2>/dev/null || true
  pkill -TERM -u "$SANGFOR_USER" -f 'xfce4/panel/wrapper-2.0' 2>/dev/null || true
  sleep 2
  pkill -KILL -u "$SANGFOR_USER" -x xrdp-chansrv 2>/dev/null || true
  pkill -KILL -u "$SANGFOR_USER" -x xfce4-session 2>/dev/null || true
  pkill -KILL -u "$SANGFOR_USER" -x xfce4-panel 2>/dev/null || true
  pkill -KILL -u "$SANGFOR_USER" -x xfce4-notifyd 2>/dev/null || true
  pkill -KILL -u "$SANGFOR_USER" -x Xorg 2>/dev/null || true
  pkill -KILL -u "$SANGFOR_USER" -f 'xfce4/panel/wrapper-2.0' 2>/dev/null || true

  # 4) 最后关掉 xrdp 入口
  pkill -TERM -x xrdp 2>/dev/null || true
  pkill -TERM -x xrdp-sesman 2>/dev/null || true
  sleep 2
  pkill -KILL -x xrdp 2>/dev/null || true
  pkill -KILL -x xrdp-sesman 2>/dev/null || true

  # 5) 记录结果
  gui_log "--- remaining gui-ish processes ---"
  ps -eo pid,ppid,user,cmd | grep -E 'xrdp|Xorg|xfce|aTrust' | grep -v grep >> /tmp/cleanup-gui.log || true
  gui_log "===== stop_graphical_stack end ====="
}

schedule_desktop_shutdown() {
  case "$GRACE_DESKTOP_SECONDS" in
    0|never|off|disabled)
      log "desktop auto-shutdown disabled"
      return 0
      ;;
  esac

  (
    sleep "$GRACE_DESKTOP_SECONDS"
    if desktop_running; then
      log "desktop grace period expired (${GRACE_DESKTOP_SECONDS}s), shutting down xrdp"
      stop_graphical_stack
    fi
  ) &
  DESKTOP_TIMER_PID=$!
}

boot_phase_requires_plugin() {
  local now elapsed
  now="$(date +%s)"
  elapsed="$((now - START_TS))"
  [ "$elapsed" -lt "$PLUGIN_STRICT_BOOT_SECONDS" ]
}

watchdog_interval_enabled() {
  case "$WATCHDOG_INTERVAL" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off|disabled|DISABLED|Disabled)
      return 1
      ;;
  esac

  return 0
}

watchdog_loop() {
  local danted_if="" vpn_if="" pport="" boot_requires_plugin=0
  local danted_ok=0 danted_port_ok=0 plugin_ok=0

  while true; do
    sleep "$WATCHDOG_INTERVAL"

    for f in "$PLUGIN_LOG" "$TINYPROXY_LOG" "$DANTED_LOG" "$WATCHDOG_LOG" "$XRDP_LOG" "$SESMAN_LOG"; do
      [ -f "$f" ] || touch "$f"
    done

    # tinyproxy 保活
    if ! tinyproxy_ready; then
      log "tinyproxy missing, restarting"
      start_tinyproxy
    fi

    # 启动期：必须尽量保证 plugin-daemon 可用，方便登录
    if boot_phase_requires_plugin; then
      boot_requires_plugin=1
      if ! plugin_ready; then
        log "boot phase: plugin-daemon not ready, restarting"
        restart_plugin_daemon
      fi
    else
      boot_requires_plugin=0
      # 非启动期：只要求进程存在，不再因端口丢失频繁重启
      if ! plugin_alive; then
        log "post-boot: plugin-daemon process missing, restarting"
        restart_plugin_daemon
      fi
    fi

    # 动态启动/切换 danted
    vpn_if="$(find_vpn_if | head -n1 || true)"
    if [ -n "$vpn_if" ]; then
      if [ -z "$danted_if" ]; then
        danted_if="$vpn_if"
      fi

      if ! danted_alive; then
        log "danted process missing, starting on $vpn_if"
        start_danted "$vpn_if" || true
        danted_if="$vpn_if"
      elif [ "$vpn_if" != "$danted_if" ]; then
        log "vpn interface changed from $danted_if to $vpn_if, restarting danted"
        start_danted "$vpn_if" || true
        danted_if="$vpn_if"
      elif ! is_port_listening 1080; then
        log "danted process alive but 1080 not listening; deferring restart until vpn health check fails"
      fi
    else
      if danted_ready; then
        log "vpn interface disappeared, stopping danted"
        cleanup_pid "${DANTED_PID:-}"
        DANTED_PID=""
        danted_if=""
        DANTED_IF=""
      fi
    fi

    restart_core_if_stuck || true

    # 当前本地状态快照
    danted_ok=0
    danted_port_ok=0
    plugin_ok=0
    danted_alive && danted_ok=1
    is_port_listening 1080 && danted_port_ok=1
    plugin_ready && plugin_ok=1

    # 未配置业务 URL 时只维护本地入口，避免开源默认值绑定私有内网地址
    if ! vpn_http_check_enabled; then
      if [ -n "$vpn_if" ] && { [ "$danted_ok" -ne 1 ] || [ "$danted_port_ok" -ne 1 ]; }; then
        log "vpn http health check disabled + local socks unhealthy -> restarting danted on $vpn_if"
        start_danted "$vpn_if" || true
      else
        log "vpn http health check disabled; local components ok"
      fi
      continue
    fi

    # VPN 实际健康检查
    # 只要配置的探测地址能通，就认为链路正常，不因为 daemon thrift 端口偶发丢失而折腾
    if vpn_http_ok; then
      log "vpn health check ok"
      continue
    fi

    # 到这里说明 VPN 不通
    log "vpn health check failed (plugin_ok=$plugin_ok danted_ok=$danted_ok danted_port_ok=$danted_port_ok vpn_if=${vpn_if:-none})"

    # 启动期内，登录依赖 daemon，这时更激进一点
    if [ "$boot_requires_plugin" -eq 1 ] && [ "$plugin_ok" -ne 1 ]; then
      log "boot phase + vpn failed + plugin not ready -> restarting plugin-daemon"
      restart_plugin_daemon
      sleep 2
      if vpn_http_ok; then
        log "vpn recovered after plugin-daemon restart"
        continue
      fi
    fi

    # danted 真挂了，或 1080 真没监听，再动本地 socks 层。
    # 业务 URL 失败通常是 aTrust 上游隧道/登录态问题，不能反复重启本地 SOCKS。
    if [ -n "$vpn_if" ] && { [ "$danted_ok" -ne 1 ] || [ "$danted_port_ok" -ne 1 ]; }; then
      log "vpn failed + local socks unhealthy -> restarting danted on $vpn_if"
      start_danted "$vpn_if" || true
      sleep 2
      if vpn_http_ok; then
        log "vpn recovered after danted restart"
        continue
      fi
    fi

    # 到这里，本地入口和 plugin 看起来都还在，但链路仍失败
    log "vpn failed while local socks/plugin look healthy -> likely xtunnel/region tunnel upstream issue; skipping local restarts"

    # xrdp 在5分钟后允许关闭，不作为容器生死条件
    # 所以这里不再因为 xrdp 退出而整体失败
  done
}

wait_without_watchdog() {
  log "watchdog disabled by WATCHDOG_INTERVAL=${WATCHDOG_INTERVAL}; skipping health checks and automatic restarts"
  tail -f /dev/null &
  KEEPALIVE_PID=$!
  wait "$KEEPALIVE_PID"
}

main() {
  ensure_dirs
  ensure_localhost_sangfor_host
  ensure_dbus
  write_tinyproxy_conf
  configure_eintr_preload

  start_plugin_daemon
  start_tinyproxy
  start_xrdp
  schedule_desktop_shutdown

  # 核心设计：
  # 1. 不再把 xrdp / sesman 当成容器必须常驻的关键进程
  # 2. WATCHDOG_INTERVAL=0 时只维持容器存活，不做健康检查和自动重启
  if watchdog_interval_enabled; then
    watchdog_loop &
    WATCHDOG_PID=$!
    wait "$WATCHDOG_PID"
  else
    wait_without_watchdog
  fi
}

main "$@"
