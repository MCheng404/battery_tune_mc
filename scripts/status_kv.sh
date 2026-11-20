#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
. $XBT/scripts/common.sh

BAT=/sys/class/power_supply/battery
_nodes=$(direct_current_nodes)
_node=$(echo "$_nodes" | head -n 1)
_v=$(read_voltage_uv)
_target=$(target_current_ma "$_v")
_ma_raw=$(cat "$BAT/current_now" 2>/dev/null)
_soc=$(cat "$BAT/capacity" 2>/dev/null)
_st=$(cat "$BAT/status" 2>/dev/null)
_tmp=$(cat "$BAT/temp" 2>/dev/null)
_cfull=$(cat "$BAT/charge_full" 2>/dev/null)
_cdes=$(cat "$BAT/charge_full_design" 2>/dev/null)
_health=$(cat "$BAT/health" 2>/dev/null)
_cycle=$(cat /sys/class/xm_power/fg_master/cyclecount 2>/dev/null)
[ -z "$_cycle" ] && _cycle=$(cat "$BAT/cycle_count" 2>/dev/null)
# µAh -> mAh
case "$_cfull" in ''|*[!0-9]*) _cfull_mah="" ;; *) _cfull_mah=$(awk -v x="$_cfull" 'BEGIN{printf "%d", x/1000}') ;; esac
case "$_cdes"  in ''|*[!0-9]*) _cdes_mah=""  ;; *) _cdes_mah=$(awk -v x="$_cdes" 'BEGIN{printf "%d", x/1000}') ;; esac
case "$_cycle" in ''|*[!0-9]*) _cycle="" ;; esac

case "$_ma_raw" in
  ''|*[!0-9-]*) _ma="" ;;
  *) _ma=$(awk -v r="$_ma_raw" 'BEGIN { printf "%d", r / 1000 }') ;;
esac
case "$_ma" in
  ''|*[!0-9-]*) _ma="" ;;
  *) _abs=${_ma#-}; { [ "$_abs" -le 30000 ]; } 2>/dev/null || _ma="" ;;
esac
unset _abs 2>/dev/null
case "$_soc" in
  ''|*[!0-9]*) _soc="" ;;
  *) { [ "$_soc" -ge 0 ] && [ "$_soc" -le 100 ]; } 2>/dev/null || _soc="" ;;
esac
# Sensor glitch guard: a single bogus sample must not reach the UI as a real
# reading. Ranges are physical plausibility bounds, not control thresholds.
case "$_tmp" in
  ''|*[!0-9-]*) _tmp="" ;;
  *) { [ "$_tmp" -ge -200 ] && [ "$_tmp" -le 1500 ]; } 2>/dev/null || _tmp="" ;;
esac
case "$_v" in
  ''|*[!0-9]*) _v="" ;;
  *) { [ "$_v" -ge 2000000 ] && [ "$_v" -le 6000000 ]; } 2>/dev/null || _v="" ;;
esac
if [ -n "$_ma" ] && [ -n "$_v" ]; then
  _ma_abs=${_ma#-}
  _battery_power_w=$(awk -v i="$_ma_abs" -v v="$_v" 'BEGIN { printf "%.1f", i * v / 1000000000 }')
else
  _ma_abs=""
  _battery_power_w=""
fi

echo "direct_control=$(if [ -n "$_nodes" ]; then echo 1; else echo 0; fi)"
echo "direct_nodes=$(echo "$_nodes" | tr '\n' ',' | sed 's/,$//')"
echo "voltage_uv=${_v}"
echo "target_ma=${_target}"
echo "current_node=${_node}"
if [ -n "$_node" ] && [ -w "$_node" ]; then echo "node_ok=1"; else echo "node_ok=0"; fi
echo "battery_current_ma=${_ma}"
echo "battery_current_abs_ma=${_ma_abs}"
echo "battery_power_w=${_battery_power_w}"
echo "soc=${_soc}"
echo "status=${_st}"
echo "temp_c=${_tmp}"
echo "charge_full_mah=${_cfull_mah}"
echo "charge_design_mah=${_cdes_mah}"
echo "health=${_health}"
echo "cycle=${_cycle}"
echo "unlock=$(cfg_get unlock 1)"
echo "cloud_guard=$(cfg_get cloud_guard 1)"
echo "baa_state=$(baa_state)"
echo "thermal_remove=$(cat /sys/class/xm_power/charger/charger_thermal/wired_thermal_remove 2>/dev/null)"
echo "ctrl_limit=$(cat /sys/class/xm_power/charger/charger_thermal/wired_ctrl_limit 2>/dev/null)"

_cgpid=$(cat $XBT/state/cg.pid 2>/dev/null)
if pid_alive "$_cgpid" "charge_guard.sh"; then _cgalive=1; else _cgalive=0; fi
echo "charge_guard_alive=$_cgalive"
echo "charge_guard_ok=$_cgalive"
watchdog_alive=$(xbt_pids 'battery_tune_mc/scripts/guard_watchdog\.sh' 'battery_tune_mc/scripts/guard_watchdog.sh' | head -n1)
echo "watchdog_alive=$watchdog_alive"

_apl_pid=$(cat $XBT/state/apl.pid 2>/dev/null)
if pid_alive "$_apl_pid" "apl.sh"; then _apl_live=1; else _apl_live=0; fi
echo "apl_alive=$_apl_live"
echo "apl_pid=$_apl_pid"
echo "apl_target_ma=$(cat $XBT/state/apl_target_ma 2>/dev/null)"
echo "apl_cap_ma=$(dt_curr_cap_ma 2>/dev/null)"
echo "apl_locked=$( [ -f $XBT/state/apl_lock_until ] && echo 1 || echo 0 )"
_dev=$(cfg_get dev_code unknown)
_pb="$XBT/state/apl_profile.$_dev.kv"
echo "apl_profile=$( [ -f "$_pb" ] && echo 1 || echo 0 )"
echo "apl_best_ma=$( [ -f "$_pb" ] && grep -a '^b[0-9]=' "$_pb" 2>/dev/null | cut -d= -f2 | awk '{if($1+0>m)m=$1+0}END{if(m>0)print m}')"
echo "apl_reset_reason=$(grep -a '^_reset_' "$_pb" 2>/dev/null | tail -n1 | cut -d= -f2-)"

echo "freepps=$(cfg_get freepps 0)"
echo "freepps_runtime=$(cat /data/adb/modules/freepps/free 2>/dev/null)"
echo "touch_sample=$(cfg_get touch_sample 1)"
_touch_live=$(sh $XBT/scripts/touch.sh isactive 2>/dev/null)
echo "touch_active=${_touch_live:-0}"
echo "tw_enable=$(cfg_get tw_enable 0)"
echo "tw_limit=$(tw_limit_c)"
echo "tw_resume=$(tw_resume_c)"
echo "tw_power_w=$(tw_power_w)"
echo "tw_active=$(cat $XBT/state/tw_active 2>/dev/null)"
echo "dyn_enable=$(cfg_get dyn_enable 0)"
echo "dyn_mode=$(dyn_mode)"
echo "policy_target_ma=$_target"
echo "policy_applied_ma=$(cat $XBT/state/policy_applied_ma 2>/dev/null)"
echo "policy_suspended=$(cat $XBT/state/policy_suspended 2>/dev/null)"
echo "dyn_cut=$(cat $XBT/state/dyn_cut 2>/dev/null)"
echo "dev_code=$DEV_CODE"
echo "dev_name=$DEV_NAME"

echo "dev_maxw=$DEV_MAXW"
echo "version=$(grep '^version=' "$XBT/module.prop" 2>/dev/null | head -n1 | cut -d= -f2)"