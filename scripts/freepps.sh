#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
. $XBT/scripts/common.sh
FP=/data/adb/modules/freepps
FP_FREE=$FP/free
FP_PROP=$FP/module.prop
FP_BIN=$XBT/bin/freepps
QCOM=/sys/class/qcom-battery/pd_verifed
MTK=/sys/class/Charging_Adapter/pd_adapter/usbpd_verifed

is_foreign() {
  [ -f "$FP_PROP" ] || return 1
  grep -q '^id=freepps_rt$' "$FP_PROP" && return 1
  [ -f "$FP/service.sh" ] || [ -f "$FP/post-fs-data.sh" ]
}

ensure_dir() {
  if is_foreign; then
    log "freepps: real FreePPS module detected at $FP, yielding"
    return 1
  fi
  mkdir -p "$FP" 2>/dev/null
  [ -f "$FP_FREE" ] || printf '0' > "$FP_FREE" 2>/dev/null
  return 0
}

write_prop() {
  is_foreign && return 1
  cat > "$FP_PROP" <<'EOF'
id=freepps_rt
name=PPS Runtime
version=1
versionCode=1
author=battery_tune_mc
description=Internal PPS runtime, started on demand
EOF
  chmod 644 "$FP_PROP" 2>/dev/null
}

remove_prop() {
  [ -f "$FP_PROP" ] || return 0
  grep -q '^id=freepps_rt$' "$FP_PROP" || return 0
  rm -f "$FP_PROP" 2>/dev/null
}

freepps_pids() {
  for _p in $(xbt_pids 'battery_tune_mc/bin/[f]reepps' "$FP_BIN"); do
    pid_alive "$_p" "$FP_BIN" || continue
    [ "$(readlink "/proc/$_p/exe" 2>/dev/null)" = "$FP_BIN" ] && echo "$_p"
  done
}

is_running() {
  for _p in $(freepps_pids); do
    [ -n "$_p" ] && return 0
  done
  return 1
}

node_one() {
  for _n in "$QCOM" "$MTK"; do
    [ -e "$_n" ] || continue
    [ "$(cat "$_n" 2>/dev/null)" = "1" ] && return 0
  done
  return 1
}

set_nodes() {
  _want="$1"
  _ok=0
  for _n in "$QCOM" "$MTK"; do
    [ -e "$_n" ] || continue
    [ "$(cat "$_n" 2>/dev/null)" = "$_want" ] && continue
    chmod 664 "$_n" 2>/dev/null
    echo "$_want" > "$_n" 2>/dev/null && _ok=1
  done
  [ "$_ok" = "1" ] && log "freepps: node write $_want done"
  return 0
}

wait_ready() {
  _i=0
  while [ "$_i" -lt 8 ]; do
    node_one && return 0
    sleep 0.2
    _i=$((_i + 1))
  done
  return 1
}

start_engine() {
  if is_foreign; then
    echo "检测到独立 FreePPS 模块，已让位，请改用该模块"
    return 1
  fi
  ensure_dir || return 1
  write_prop || return 1
  printf '1' > "$FP_FREE" 2>/dev/null

  if ! is_running; then
    ( setsid "$FP_BIN" >/dev/null 2>&1 < /dev/null & )
    sleep 0.5
  fi
  if ! is_running; then
    ( setsid "$FP_BIN" >/dev/null 2>&1 < /dev/null & )
    sleep 0.5
  fi
  if ! is_running; then
    remove_prop
    log "freepps: ERROR not running after retry"
    echo "警告: FreePPS 进程启动失败，请查看模块日志"
    return 1
  fi

  wait_ready
  set_nodes 1
  remove_prop
  log "freepps: started qcom=$(cat "$QCOM" 2>/dev/null) mtk=$(cat "$MTK" 2>/dev/null)"
  if node_one; then
    echo "公版PPS已开启（节点已写入，拔插充电器后生效）"
    return 0
  fi
  echo "警告: pd_verifed 写入失败，PPS 无法解锁（检查节点权限/SELinux）"
  return 1
}

stop_engine() {
  for _p in $(freepps_pids); do
    kill -TERM "$_p" 2>/dev/null
  done
  sleep 0.4
  for _p in $(freepps_pids); do
    kill -9 "$_p" 2>/dev/null
  done
}

restore_node() {
  stop_engine
  printf '0' > "$FP_FREE" 2>/dev/null
  set_nodes 0
  remove_prop
  log "freepps: restored qcom=$(cat "$QCOM" 2>/dev/null) mtk=$(cat "$MTK" 2>/dev/null)"
}

kill_legacy() {
  xbt_kill 'FreePPS/bin/[F]reePPS' 'FreePPS/bin/FreePPS'
}

case "$1" in
  status)
    _en=$(cfg_get freepps 0)
    if [ "$_en" = "1" ]; then _ens="开启"; else _ens="关闭"; fi
    _fv=$(cat "$FP_FREE" 2>/dev/null)
    case "$_fv" in
      1) _fs="锁定PPS支持" ;;
      0) _fs="已暂停" ;;
      *) _fs="未初始化" ;;
    esac
    if is_running; then _rs="运行中"; else _rs="未运行"; fi
    if is_foreign; then _fs="检测到独立 FreePPS 模块"; fi
    echo "总开关 : $_ens (settings freepps=$_en)"
    echo "运行时 : $_fs (free=${_fv:-无})"
    echo "进程   : $_rs"
    echo "节点   : qcom=$(cat "$QCOM" 2>/dev/null) mtk=$(cat "$MTK" 2>/dev/null)"
    _pv=$(cat "$QCOM" 2>/dev/null)
    if [ "$_en" = "0" ] && [ "$_pv" = "1" ]; then
      echo "提示   : 已关闭但 qcom 节点仍为 1，执行 freepps.sh restore 还原"
    fi
    ;;
  on)
    if is_foreign; then
      echo "检测到独立 FreePPS 模块，已让位，请改用该模块"
      exit 1
    fi
    kill_legacy
    start_engine
    _rc=$?
    if [ "$_rc" = "0" ]; then
      cfg_set freepps 1
    else
      cfg_set freepps 0
      restore_node
    fi
    log "freepps: ON rc=$_rc"
    exit "$_rc"
    ;;
  off)
    cfg_set freepps 0
    restore_node
    log "freepps: OFF"
    echo "公版PPS已关闭（节点已还原）"
    ;;
  boot)
    if [ "$(cfg_get freepps 0)" = "1" ]; then
      kill_legacy
      start_engine
      log "freepps: boot -> locked"
    else
      ensure_dir
      if [ "$(cat /sys/class/power_supply/battery/status 2>/dev/null)" = "Discharging" ]; then
        node_one && set_nodes 0
      fi
      remove_prop
      log "freepps: boot -> paused"
    fi
    ;;
  restore)
    ensure_dir
    restore_node
    echo "验证节点已还原: qcom=$(cat "$QCOM" 2>/dev/null) mtk=$(cat "$MTK" 2>/dev/null)"
    ;;
  ensure)
    ensure_dir || exit 0
    if [ "$(cfg_get freepps 0)" = "1" ]; then
      if is_running; then
        if [ "$(cat "$FP_FREE" 2>/dev/null)" != "1" ]; then
          start_engine
        else
          node_one || set_nodes 1
        fi
      else
        start_engine
      fi
    else
      if is_running; then stop_engine; fi
      [ "$(cat "$FP_FREE" 2>/dev/null)" = "0" ] || printf '0' > "$FP_FREE" 2>/dev/null
      if [ "$(cat /sys/class/power_supply/battery/status 2>/dev/null)" = "Discharging" ]; then
        node_one && set_nodes 0
      fi
      remove_prop
    fi
    ;;
  *)
    echo "用法: freepps.sh status|on|off|boot|ensure|restore"
    exit 9
    ;;
esac
