#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
BAT=/sys/class/power_supply/battery
_ma_raw=$(cat "$BAT/current_now" 2>/dev/null)
_soc=$(cat "$BAT/capacity" 2>/dev/null)
_st=$(cat "$BAT/status" 2>/dev/null)
_tmp=$(cat "$BAT/temp" 2>/dev/null)
_v=$(cat "$BAT/voltage_now" 2>/dev/null)
_cfull=$(cat "$BAT/charge_full" 2>/dev/null)
_cdes=$(cat "$BAT/charge_full_design" 2>/dev/null)
_health=$(cat "$BAT/health" 2>/dev/null)

case "$_ma_raw" in
  ''|*[!0-9-]*) _ma="" ;;
  *) _ma=$(awk -v r="$_ma_raw" 'BEGIN { printf "%d", r / 1000 }') ;;
esac
case "$_ma" in
  ''|*[!0-9-]*) _ma="" ;;
  *) _abs=${_ma#-}; { [ "$_abs" -le 30000 ]; } 2>/dev/null || _ma="" ;;
esac
case "$_soc" in
  ''|*[!0-9]*) _soc="" ;;
  *) { [ "$_soc" -ge 0 ] && [ "$_soc" -le 100 ]; } 2>/dev/null || _soc="" ;;
esac
case "$_tmp" in
  ''|*[!0-9-]*) _tmp="" ;;
  *) { [ "$_tmp" -ge -200 ] && [ "$_tmp" -le 1500 ]; } 2>/dev/null || _tmp="" ;;
esac
case "$_v" in
  ''|*[!0-9]*) _v="" ;;
  *) { [ "$_v" -ge 2000000 ] && [ "$_v" -le 6000000 ]; } 2>/dev/null || _v="" ;;
esac
case "$_cfull" in ''|*[!0-9]*) _cfull_mah="" ;; *) _cfull_mah=$(awk -v x="$_cfull" 'BEGIN{printf "%d", x/1000}') ;; esac
case "$_cdes" in ''|*[!0-9]*) _cdes_mah="" ;; *) _cdes_mah=$(awk -v x="$_cdes" 'BEGIN{printf "%d", x/1000}') ;; esac

if [ -n "$_ma" ] && [ -n "$_v" ]; then
  _ma_abs=${_ma#-}
  _battery_power_w=$(awk -v i="$_ma_abs" -v v="$_v" 'BEGIN { printf "%.1f", i * v / 1000000000 }')
else
  _ma_abs=""
  _battery_power_w=""
fi

echo "battery_current_ma=${_ma}"
echo "battery_current_abs_ma=${_ma_abs}"
echo "battery_power_w=${_battery_power_w}"
echo "soc=${_soc}"
echo "status=${_st}"
echo "temp_c=${_tmp}"
echo "voltage_uv=${_v}"
echo "charge_full_mah=${_cfull_mah}"
echo "charge_design_mah=${_cdes_mah}"
echo "health=${_health}"
echo "tw_active=$(cat $XBT/state/tw_active 2>/dev/null)"
echo "policy_suspended=$(cat $XBT/state/policy_suspended 2>/dev/null)"
echo "policy_applied_ma=$(cat $XBT/state/policy_applied_ma 2>/dev/null)"
echo "dyn_cut=$(cat $XBT/state/dyn_cut 2>/dev/null)"