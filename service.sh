#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
. $XBT/scripts/common.sh

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 90 ]; do
  sleep 2; i=$((i+1))
done
# ============================================================================

xbt_clean_stuck_tr

log "service: start (boot_completed=$(getprop sys.boot_completed), waited ${i}x2s)"

UNLOCK=$(cfg_get unlock 1)
FV=$(cfg_get fv_guard 1)
PSSD=$(cfg_get pss_disable 1)

if [ "$UNLOCK" = "1" ]; then
  _st=$(sh $XBT/scripts/baa_ops.sh check 2>/dev/null)
  case "$_st" in
    active) log "service: baa active" ;;
    skipped) log "service: baa skipped (target empty) [v3.9.9 起此分支已不产生，空BAA会照常挂载]" ;;
    *)
      log "service: baa state=$_st, retry mount"
      baa_refresh_src >/dev/null 2>>"$LOG"
      sh $XBT/scripts/baa_ops.sh mount >>"$LOG" 2>&1
      ;;
  esac
else
  sh $XBT/scripts/baa_ops.sh umount >>"$LOG" 2>&1
fi

if [ "$UNLOCK" = "1" ] && [ "$FV" = "1" ]; then
  sh $XBT/scripts/fv_guard.sh start >>"$LOG" 2>&1
else
  sh $XBT/scripts/fv_guard.sh stop >>"$LOG" 2>&1
fi

#         isBatteryLifeFunctionSupported: true
#         getBatterySoh: 95 / getBatteryCycleCount: 20
#         batteryHealthByUsingTime/byCycleCount/bySoh / calculateUiSohSum: 217

_ps=$(pss_state)

if [ ! -f "$XBT/state/pss_initial" ] && [ -n "$_ps" ]; then
  mkdir -p "$XBT/state" 2>/dev/null
  echo "$_ps" > "$XBT/state/pss_initial" 2>/dev/null
fi
if [ "$PSSD" = "1" ]; then

  _pss_low=$(cfg_get pss_low_soc 0)
  case "$_pss_low" in ''|*[!0-9]*) _pss_low=0 ;; esac
  if [ "$_pss_low" -gt 0 ] 2>/dev/null; then
    pss_guard_tick
    log "service: PSS dynamic mode (low_soc=${_pss_low}%, now=$(pss_state))"
  elif [ "$_ps" != "disabled" ]; then
    pm disable "$PSS" >>"$LOG" 2>&1

    echo 1 > "$XBT/state/pss_disabled_by_module" 2>/dev/null
    rm -f "$XBT/state/pss_dynamic" 2>/dev/null
    log "service: PSS disable requested (now $(pss_state))"
  else
    log "service: PSS already disabled"
  fi
else

  if [ "$_ps" = "disabled" ] && [ "$(cat "$XBT/state/pss_disabled_by_module" 2>/dev/null)" = "1" ]; then
    pm enable "$PSS" >>"$LOG" 2>&1
    rm -f "$XBT/state/pss_disabled_by_module" 2>/dev/null
    log "service: PSS re-enabled (was disabled by module, restore battery health)"
  elif [ "$_ps" = "disabled" ]; then

    log "service: PSS disabled but not by module (left as-is; battery health may be hidden)"
  fi
fi

cycle_real_capture
_rc=$(cat "$CYCLE_REAL_FILE" 2>/dev/null)
log "service: real cycle = ${_rc:-未知} (qmax=$(cat $CYCLE_REAL_NODE 2>/dev/null) node=$(cat $CYCLE_NODE 2>/dev/null))"

CF=$(cfg_get cycle_fake "")
if [ -n "$CF" ]; then
  _cur=$(cat "$CYCLE_NODE" 2>/dev/null)
  if [ -n "$_cur" ] && [ "$_cur" != "$CF" ]; then
    chmod 666 "$CYCLE_NODE" 2>/dev/null
    echo "$CF" > "$CYCLE_NODE" 2>/dev/null
    log "service: cycle_fake $_cur -> $CF"
  fi

  if [ -e "$CYCLE_NODE2" ]; then
    _cur2=$(cat "$CYCLE_NODE2" 2>/dev/null)
    if [ -n "$_cur2" ] && [ "$_cur2" != "$CF" ]; then
      chmod 666 "$CYCLE_NODE2" 2>/dev/null
      echo "$CF" > "$CYCLE_NODE2" 2>/dev/null
    fi
  fi
fi

if [ -n "$CF" ]; then
  sh $XBT/scripts/cycle_guard.sh start >>"$LOG" 2>&1
else
  sh $XBT/scripts/cycle_guard.sh stop >>"$LOG" 2>&1
fi

BAT=/sys/class/power_supply/battery
_HEALTH=$(awk -v c="$(cat $BAT/charge_full 2>/dev/null || echo 0)" -v d="$(cat $BAT/charge_full_design 2>/dev/null || echo 0)" 'BEGIN{ if (d>0) printf "%.1f", c/d*100; else printf "?" }')
_CYCLE=$(cat /sys/class/xm_power/fg_master/cyclecount 2>/dev/null)
[ -z "$_CYCLE" ] && _CYCLE=$(cat $BAT/cycle_count 2>/dev/null)
update_desc "$_HEALTH" "$_CYCLE" "$UNLOCK"

_log_sz=$(wc -c < "$LOG" 2>/dev/null)
case "$_log_sz" in
  ''|*[!0-9]*) ;;
  *)
    if [ "$_log_sz" -gt 2097152 ]; then
      tail -n 10000 "$LOG" > "$LOG.rot" 2>/dev/null && mv -f "$LOG.rot" "$LOG" 2>/dev/null
      log "service: log rotated (was ${_log_sz} bytes -> keep last 10000 lines)"
    fi
    ;;
esac

POWER_NODE=$(direct_current_nodes | head -n 1)
CUR_NODE=$(current_node)
if { [ -n "$POWER_NODE" ] && [ -w "$POWER_NODE" ]; } || { [ -n "$CUR_NODE" ] && [ -w "$CUR_NODE" ]; }; then
  mkdir -p $XBT/state 2>/dev/null

  snapshot_current_limit "$CUR_NODE"
  snapshot_control_limit

  direct_set_thermal
  log "service: thermal_remove -> $(thermal_target)"
else
  log "service: no writable charge-current node; thermal node left unchanged"
fi

# Re-launch so an in-place module update never keeps an old guard process.

if [ "$UNLOCK" = "1" ]; then
  xbt_kill 'battery_tune_mc/scripts/charge_guard\.sh' 'battery_tune_mc/scripts/charge_guard.sh'
  ( setsid sh $XBT/scripts/charge_guard.sh >/dev/null 2>&1 < /dev/null & )
  log "service: charge_guard started (direct) for inf"

  sleep 2
  xbt_kill 'battery_tune_mc/scripts/guard_watchdog\.sh' 'battery_tune_mc/scripts/guard_watchdog.sh'
  ( setsid sh $XBT/scripts/guard_watchdog.sh >/dev/null 2>&1 < /dev/null & )
  log "service: guard_watchdog started (PID-file 模式，charge_guard 掉线自愈)"
else
  log "service: unlock=0, charge_guard not started"
fi

xbt_kill 'battery_tune_mc/scripts/cloud_guard\.sh watch' 'battery_tune_mc/scripts/cloud_guard.sh watch'
( setsid sh $XBT/scripts/cloud_guard.sh watch >/dev/null 2>&1 < /dev/null & )
log "service: cloud_guard watch started"

xbt_kill 'battery_tune_mc/scripts/apl\.sh' 'battery_tune_mc/scripts/apl.sh'
rm -f "$XBT/state/apl_target_ma" "$XBT/state/apl_lock_until" "$XBT/state/apl_urgent" 2>/dev/null
( setsid sh $XBT/scripts/apl.sh >/dev/null 2>&1 < /dev/null & )
log "service: apl(自适应功率爬坡器) started"

sh $XBT/scripts/freepps.sh boot >>"$LOG" 2>&1

rm -f "$XBT/state/inf_settle_ts" "$XBT/state/inf_selfcheck_ts" \
      "$XBT/state/cg_last_write_ts" "$XBT/state/cg_gap_log_ts" 2>/dev/null

rm -f "$XBT/state/inf_settled" "$XBT/state/inf_settle_fail" 2>/dev/null

if [ -f "$XBT/state/inf_node_capped" ] && [ ! -f "$XBT/state/_mig_381_capped" ]; then
  _oc=$(cat "$XBT/state/inf_node_capped" 2>/dev/null)
  rm -f "$XBT/state/inf_node_capped" 2>/dev/null
  : > "$XBT/state/_mig_381_capped" 2>/dev/null
  log "service: v3.8.1 迁移 — 已清除旧版误判的 inf_node_capped (原值 ${_oc:-?}；无线节点被误算进最小值所致)"
fi

log "service: cleared stale throttle timestamps (inf_settle_ts/cg_last_write_ts/inf_settled)"
log "service: end"

exit 0
