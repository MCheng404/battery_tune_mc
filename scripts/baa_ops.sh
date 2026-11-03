#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc

if [ "${XBT_IN_PID1:-0}" != "1" ]; then

  for _ns in /system/bin/nsenter /system/xbin/nsenter \
             /data/adb/ksu/bin/nsenter /data/adb/magisk/nsenter; do
    if [ -x "$_ns" ]; then
      exec "$_ns" -t 1 -m -- /system/bin/env XBT_IN_PID1=1 /system/bin/sh "$0" "$@"
    fi
  done
  export XBT_IN_PID1=1 XBT_NO_NSENTER=1
fi

. $XBT/scripts/common.sh

MODE="$1"

case "$MODE" in
  mount)
    [ "$XBT_NO_NSENTER" = "1" ] && log "baa_ops: WARN nsenter not found, mounting in current namespace"
    [ -f "$BAA_SRC" ] || { log "baa_ops: src missing ($BAA_SRC)"; exit 1; }
    [ -f "$BAA_TGT" ] || { log "baa_ops: target missing ($BAA_TGT not present / odm not mounted?)"; exit 2; }

    _ssz=$(stat -c %s "$BAA_SRC" 2>/dev/null)
    case "$_ssz" in ''|*[!0-9]*) _ssz=0 ;; esac
    if [ "$_ssz" -le 8 ]; then
      log "baa_ops: src empty (${_ssz}B) -> skip mount (protect target)"
      exit 1
    fi
    _tsz=$(stat -c %s "$BAA_TGT" 2>/dev/null)
    case "$_tsz" in ''|*[!0-9]*) _tsz=0 ;; esac
    if [ "$_tsz" -le 8 ]; then

      #      ichg_limit = buck eff_client:volt_thermal_limit 4500  (4.5A)
      #      iin_limit  = buck eff_client:volt_limit 3000          (3A)

      log "baa_ops: target is EMPTY (${_tsz}B, ROM BAA-less) -> mounting module BAA anyway (v3.9.9: empty target means no system constraint, our config is a strict improvement)"
    fi
    if grep -F " $BAA_TGT " /proc/mounts >/dev/null 2>&1; then
      umount "$BAA_TGT" 2>>"$LOG"
    fi
    _org=$(stat -c '%C' "$BAA_TGT" 2>/dev/null)
    _use="${_org:-$BAA_LABEL}"
    chcon "$_use" "$BAA_SRC" 2>>"$LOG"
    chmod 0644 "$BAA_SRC" 2>>"$LOG"
    if mount -o bind "$BAA_SRC" "$BAA_TGT" 2>>"$LOG"; then
      _s=$(hash_of "$BAA_SRC"); _t=$(hash_of "$BAA_TGT"); _l=$(stat -c '%C' "$BAA_TGT" 2>/dev/null)
      if [ "$_s" = "$_t" ] && [ "$_l" = "$_use" ]; then
        log "baa_ops: mount OK (sha256+label verified)"
        exit 0
      else
        umount "$BAA_TGT" 2>>"$LOG"
        log "baa_ops: mount verify FAILED, rolled back"
        exit 3
      fi
    else
      log "baa_ops: mount FAILED"
      exit 4
    fi
    ;;
  umount)
    if grep -F " $BAA_TGT " /proc/mounts >/dev/null 2>&1; then
      umount "$BAA_TGT" 2>>"$LOG" && log "baa_ops: umounted" || log "baa_ops: umount failed"
    else
      log "baa_ops: umount no-op (not mounted)"
    fi
    exit 0
    ;;
  check)
    baa_state
    ;;
  *)
    echo "usage: $0 mount|umount|check"; exit 9
    ;;
esac
