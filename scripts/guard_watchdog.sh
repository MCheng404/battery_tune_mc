#!/system/bin/sh
# ============================================================================

# ----------------------------------------------------------------------------

#

#

# ============================================================================
XBT=/data/adb/modules/battery_tune_mc
LOG="${LOG:-/data/local/tmp/xt_toolbox.log}"
PIDF="$XBT/state/cg.pid"
LASTF="$XBT/state/wd_last_restart"

[ -f "$XBT/scripts/common.sh" ] && . "$XBT/scripts/common.sh" 2>/dev/null

if ! command -v cfg_get >/dev/null 2>&1; then
  cfg_get() {
    _cgf="$XBT/config/settings.conf"
    _cgk="$1"; _cgd="$2"
    [ -f "$_cgf" ] || { printf '%s' "$_cgd"; return; }
    _cgv=$(grep -a "^${_cgk}=" "$_cgf" 2>/dev/null | head -n1 | cut -d= -f2-)
    [ -n "$_cgv" ] && printf '%s' "$_cgv" || printf '%s' "$_cgd"
  }
fi

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') guard_watchdog: $*" >> "$LOG" 2>/dev/null; }

cg_alive() {
  [ -s "$PIDF" ] || return 1
  _pid=$(cat "$PIDF" 2>/dev/null)
  case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_pid" -gt 1 ] 2>/dev/null || return 1

  _tsf="$XBT/state/cg_started_ts"
  if [ -s "$_tsf" ]; then
    _ts=$(cat "$_tsf" 2>/dev/null); _now=$(date +%s)
    case "$_ts" in ''|*[!0-9]*) ;; *)
      [ $((_now - _ts)) -gt 86400 ] && return 1 ;;
    esac
  fi

  kill -0 "$_pid" 2>/dev/null || return 1
  return 0
}

restart_cg() {
  _now=$(date +%s)
  _last=$(cat "$LASTF" 2>/dev/null)
  case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
  if [ $((_now - _last)) -lt 60 ]; then
    log "跳过重启（60 秒全局限流内，上次 $_last）"
    return 1
  fi
  echo "$_now" > "$LASTF" 2>/dev/null

  log "检测到 charge_guard 掉线（pidfile=$(cat "$PIDF" 2>/dev/null)），正在重启"
  rm -f "$PIDF" 2>/dev/null
  ( setsid sh $XBT/scripts/charge_guard.sh >/dev/null 2>&1 < /dev/null & )
  sleep 3
  if cg_alive; then
    log "重启成功 pid=$(cat "$PIDF" 2>/dev/null)"
  else
    log "⚠ 重启后仍不存活，等待下一轮"
  fi
}

log "started (pid $$, PID-file 模式，不读 /proc/<pid>/cmdline)"

TICK=0
while :; do
  TICK=$((TICK + 1))

  if ! cg_alive; then
    restart_cg
  elif [ $((TICK % 30)) -eq 1 ]; then

    log "alive pid=$(cat "$PIDF" 2>/dev/null)"
  fi
  sleep 60
done
