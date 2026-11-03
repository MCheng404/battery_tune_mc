#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
. $XBT/scripts/common.sh

PIDFILE=/data/local/tmp/xt_fv_guard.pid
HANDLER=$XBT/scripts/fv_handler.sh

_guard_alive() {
  _p="$1"
  case "$_p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_p" 2>/dev/null || return 1

  _cl=$(timeout 1 cat "/proc/$_p/cmdline" 2>/dev/null | tr '\0' ' ')
  case "$_cl" in
    *fv_guard*|*fv_handler*|*inotifyd*) return 0 ;;
  esac
  return 1
}

_spawn() {

  #

  if [ ! -f "$XBT/state/fv_default" ]; then
    mkdir -p "$XBT/state" 2>/dev/null
    _fv0=""; _src=""
    if [ -f "$BAA_STOCK" ]; then
      _raw0=$(cat "$BAA_STOCK" 2>/dev/null)
      case "$_raw0" in
        BAA_ENC:*) : ;;
        *)
          _fv0=$(printf '%s' "$_raw0" | grep -o '"smart_fv"[^}]*"value":[0-9]*' 2>/dev/null | \
                 grep -o '[0-9]*$' | sort -n | tail -n 1)
          [ -n "$_fv0" ] && _src="stock"
          ;;
      esac
    fi
    if [ -z "$_fv0" ]; then

      case "$DEV_CODE" in
        haotian)
          _fv0=40; _src="table" ;;
        *) : ;;
      esac
    fi
    if [ -z "$_fv0" ]; then
      _fv0=$(cat "$FV_NODE" 2>/dev/null)
      _src="node"
    fi
    case "$_fv0" in
      ''|*[!0-9]*) : ;;
      *)
        echo "$_fv0" > "$XBT/state/fv_default" 2>/dev/null
        echo "$_src" > "$XBT/state/fv_default_src" 2>/dev/null
        log "fv_guard: uninstall-restore target smart_fv=${_fv0} (source=$_src)"
        ;;
    esac
  fi
  /system/bin/inotifyd "$HANDLER" "$FV_NODE:w" >/dev/null 2>&1 &
  ( while true; do
      _v=$(cat "$FV_NODE" 2>/dev/null)
      if [ -n "$_v" ] && [ "$_v" != "0" ]; then
        echo 0 > "$FV_NODE" 2>/dev/null
        log "fv_guard: [loop] $_v -> 0"
      fi
      sleep 10
    done ) &
  echo $! > "$PIDFILE"
  log "fv_guard: started pid=$(cat $PIDFILE)"
  echo "started (pid $(cat $PIDFILE))"
}

start_guard() {
  if [ -f "$PIDFILE" ]; then
    _p=$(cat "$PIDFILE" 2>/dev/null)
    if _guard_alive "$_p"; then
      echo "already running (pid $_p)"
      return 0
    fi

    rm -f "$PIDFILE"
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$XBT/scripts/fv_guard.sh" _spawn >/dev/null 2>&1
    _t=0
    while [ "$_t" -lt 5 ]; do
      sleep 1
      _t=$((_t+1))
      _p=$(cat "$PIDFILE" 2>/dev/null)
      if _guard_alive "$_p"; then
        echo "started (pid $_p)"
        return 0
      fi
    done
  fi
  _spawn
}

stop_guard() {
  if [ -f "$PIDFILE" ]; then
    _p=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null
    rm -f "$PIDFILE"
  fi
  for _q in $(timeout 5 pgrep -f "$HANDLER" 2>/dev/null); do
    kill -9 "$_q" 2>/dev/null
  done
  log "fv_guard: stopped"
  echo "stopped"
}

status_guard() {
  _fv=$(cat "$FV_NODE" 2>/dev/null)
  if [ -f "$PIDFILE" ] && _guard_alive "$(cat "$PIDFILE" 2>/dev/null)"; then
    echo "running (pid $(cat $PIDFILE), fv=$_fv)"
  else
    echo "not running (fv=$_fv)"
  fi
}

case "$1" in
  start) start_guard ;;
  _spawn) _spawn ;;
  stop) stop_guard ;;
  status) status_guard ;;
  *) echo "usage: $0 start|stop|status"; exit 9 ;;
esac
