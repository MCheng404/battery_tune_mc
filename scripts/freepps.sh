#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
. $XBT/scripts/common.sh
FP=/data/adb/modules/freepps
FP_FREE=$FP/free
FP_BIN=$XBT/bin/freepps

ensure_dir() {
  mkdir -p $FP 2>/dev/null
  [ -f $FP_FREE ] || printf '0' > $FP_FREE 2>/dev/null

  if [ -f "$FP/module.prop" ]; then
    if [ ! -f "$FP/post-fs-data.sh" ] && [ ! -f "$FP/service.sh" ]; then
      rm -f "$FP/module.prop" 2>/dev/null
      log "freepps: removed self-created ghost module.prop"
    else
      log "freepps: detected REAL FreePPS module at $FP -> left untouched"
    fi
  fi
}

is_running() {

  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f 'battery_tune_mc/bin/[f]reepps' >/dev/null 2>&1 && return 0
    return 1
  fi

  for _p in /proc/[0-9]*; do
    case "$(timeout 1 cat $_p/comm 2>/dev/null)" in
      freepps)
        case "$(timeout 1 cat "$_p/cmdline" 2>/dev/null | tr '\0' ' ')" in
          *battery_tune_mc/bin/freepps*) return 0 ;;
        esac
        ;;
    esac
  done
  return 1
}

restore_node() {
  _q=/sys/class/qcom-battery/pd_verifed
  _c=/sys/class/Charging_Adapter/pd_adapter/usbpd_verifed

  printf '0' > $FP_FREE 2>/dev/null

  _need=0
  for _n in $_q $_c; do
    [ -e "$_n" ] || continue
    [ "$(cat "$_n" 2>/dev/null)" = "1" ] && _need=1
  done
  [ "$_need" = "0" ] && return 0

  if is_running; then
    _i=0
    while [ $_i -lt 6 ]; do
      _i=$((_i + 1))
      sleep 1
      _still=0
      for _n in $_q $_c; do
        [ -e "$_n" ] || continue
        [ "$(cat "$_n" 2>/dev/null)" = "1" ] && _still=1
      done
      [ "$_still" = "0" ] && return 0
    done
  fi

  _ok=0
  for _n in $_q $_c; do
    [ -e "$_n" ] || continue
    chmod 664 "$_n" 2>/dev/null
    echo 0 > "$_n" 2>/dev/null && _ok=1
  done
  [ "$_ok" = "1" ] && log "freepps: pd_verifed force-restored to 0 (process was not running)"
  return 0
}

kill_legacy() {
  if command -v pgrep >/dev/null 2>&1; then
    for _k in $(timeout 5 pgrep -f 'FreePPS/bin/[F]reePPS' 2>/dev/null); do
      kill -9 "$_k" 2>/dev/null
    done
    return
  fi

  for _p in /proc/[0-9]*; do
    case "$(timeout 1 cat $_p/comm 2>/dev/null)" in
      FreePPS)
        case "$(timeout 1 cat "$_p/cmdline" 2>/dev/null | tr '\0' ' ')" in
          */FreePPS/bin/FreePPS*) kill -9 "${_p#/proc/}" 2>/dev/null ;;
        esac
        ;;
    esac
  done
}

ensure_running() {
  [ -x $FP_BIN ] || { echo "二进制缺失: $FP_BIN"; return 1; }

  _lk=$XBT/state/.freepps.lock
  _owns=""
  if [ -d "$_lk" ]; then
    _age=$(( $(date +%s) - $(stat -c %Y "$_lk" 2>/dev/null || echo 0) ))
    [ "$_age" -gt 30 ] && rm -rf "$_lk" 2>/dev/null
  fi
  if mkdir "$_lk" 2>/dev/null; then
    _owns=1
  else

    sleep 0.4
    if is_running; then return 0; fi
    rm -rf "$_lk" 2>/dev/null
    if mkdir "$_lk" 2>/dev/null; then _owns=1; else return 0; fi
  fi
  trap '[ -n "$_owns" ] && rmdir "$_lk" 2>/dev/null' EXIT
  if ! is_running; then
    ( setsid $FP_BIN >/dev/null 2>&1 < /dev/null & )
    log "freepps: process started"
    echo "FreePPS 进程已启动"
  fi
  sleep 0.3
  if ! is_running; then

    ( setsid $FP_BIN >/dev/null 2>&1 < /dev/null & )
    sleep 0.3
    if is_running; then
      log "freepps: process restarted (2nd try)"
      echo "FreePPS 进程已启动（重试）"
    else
      log "freepps: ERROR process not running after retry"
      echo "警告: FreePPS 进程启动失败，请查看模块日志"
    fi
  fi
  rmdir "$_lk" 2>/dev/null
}

case "$1" in
  status)
    _en=$(cfg_get freepps 0)
    if [ "$_en" = "1" ]; then _ens="开启"; else _ens="关闭"; fi
    _fv=$(cat $FP_FREE 2>/dev/null)
    case "$_fv" in
      1) _fs="锁定PPS支持" ;;
      0) _fs="已暂停" ;;
      *) _fs="未初始化" ;;
    esac
    if is_running; then _rs="运行中"; else _rs="未运行"; fi
    echo "总开关 : $_ens (settings freepps=$_en)"
    echo "运行时 : $_fs (free=${_fv:-无})"
    echo "进程   : $_rs"
    echo "节点   : pd_verifed=$(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)"
    _pv=$(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)
    if [ "$_en" = "0" ] && [ "$_pv" = "1" ]; then
      echo "警告   : ⚠ 已关闭但 pd_verifed 仍为 1（残留）→ 执行 freepps.sh restore 还原"
    fi
    ;;
  on)
    cfg_set freepps 1
    ensure_dir
    printf '1' > $FP_FREE 2>/dev/null
    kill_legacy
    ensure_running
    log "freepps: ON"
    echo "公版PPS解锁已开启（含金标动画；切换/重插充电器后生效）"
    ;;
  off)
    cfg_set freepps 0
    ensure_dir
    printf '0' > $FP_FREE 2>/dev/null
    restore_node
    log "freepps: OFF"
    echo "公版PPS解锁已关闭（验证节点已还原；进程保留待命）"
    ;;
  boot)
    if [ "$(cfg_get freepps 0)" = "1" ]; then
      ensure_dir
      printf '1' > $FP_FREE 2>/dev/null
      kill_legacy
      ensure_running
      log "freepps: boot -> locked"
    else
      if [ -d $FP ]; then
        ensure_dir

        restore_node
      fi
      log "freepps: boot -> paused"
    fi
    ;;
  restore)

    ensure_dir
    restore_node
    echo "验证节点已还原: pd_verifed=$(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)"
    log "freepps: restore node -> $(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)"
    ;;
  ensure)
    ensure_dir
    if [ "$(cfg_get freepps 0)" = "1" ]; then
      [ "$(cat $FP_FREE 2>/dev/null)" = "1" ] || printf '1' > $FP_FREE 2>/dev/null
      ensure_running
    else
      if [ "$(cat $FP_FREE 2>/dev/null)" != "0" ]; then
        restore_node
      else

        _pv=$(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)
        [ "$_pv" = "1" ] && restore_node
      fi
    fi
    ;;
  *)
    echo "用法: freepps.sh status|on|off|boot|ensure|restore"
    exit 9
    ;;
esac
