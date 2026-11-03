#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
. $XBT/scripts/common.sh

log "pfd: begin"

rm -f /data/local/tmp/xt_fv_guard.pid 2>/dev/null

KSUD=/data/adb/ksu/bin/ksud
if [ -x "$KSUD" ]; then
  KSU_MODULE=battery_tune_mc "$KSUD" module config set manage.kernel_umount false >>"$LOG" 2>&1
fi

if [ "$(cfg_get unlock 1)" = "1" ]; then
  baa_refresh_src >/dev/null 2>>"$LOG"
  sh $XBT/scripts/baa_ops.sh mount >>"$LOG" 2>&1
  _rc=$?
  log "pfd: mount exit=$_rc"
else
  log "pfd: unlock=0, skip mount"
fi

if [ "$(cfg_get cloud_guard 1)" = "1" ]; then
  sh $XBT/scripts/cloud_guard.sh early >>"$LOG" 2>&1
fi
exit 0
