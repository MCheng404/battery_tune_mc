#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
. $XBT/scripts/common.sh

BAT=/sys/class/power_supply/battery
UNLOCK=$(cfg_get unlock 1)
if [ "$UNLOCK" = "1" ]; then _u="开"; else _u="关"; fi
_CAP=$(cat $BAT/capacity 2>/dev/null)
_ST=$(cat $BAT/status 2>/dev/null)
_T=$(awk -v t="$(cat $BAT/temp 2>/dev/null)" 'BEGIN{printf "%.1f", t/10}')
_V=$(awk -v v="$(cat $BAT/voltage_now 2>/dev/null)" 'BEGIN{printf "%.2f", v/1000000}')
_D=$(cat $BAT/charge_full_design 2>/dev/null); _C=$(cat $BAT/charge_full 2>/dev/null)
_H=$(awk -v c="$_C" -v d="$_D" 'BEGIN{ if(d>0) printf "%.1f", c/d*100; else printf "?" }')
_CYC=$(cat /sys/class/xm_power/fg_master/cyclecount 2>/dev/null)
_CF=$(cfg_get cycle_fake "")
_LR=$(cat $XBT/state/last_real_cycle.txt 2>/dev/null)
case "$_LR" in ''|*[!0-9]*) _LR="" ;; esac
if [ -n "$_CF" ]; then
  if [ -n "$_LR" ]; then _CYC_D="${_CYC}（伪装）· 真实 ${_LR}"
  else _CYC_D="${_CYC}（伪装中）"; fi
else
  _CYC_D="${_CYC}"
fi

FVS=$(sh $XBT/scripts/fv_guard.sh status 2>/dev/null | head -n 1)

echo "===================================="
echo "[电池解容工具箱] 状态快照"
echo "===================================="
echo "模块版本 : $(grep '^version=' $XBT/module.prop 2>/dev/null | head -n1 | cut -d= -f2)"
echo "解容开关 : $_u"
echo "BAA挂载  : $(baa_state_cn)"
cloud_line
echo "smart_fv : $(cat $FV_NODE 2>/dev/null)  ($FVS)"
echo "低电锁容服务: $(pss_state)"
echo "当前槽   : _$(slot_letter)"
echo "------------------------------------"
echo "电量 ${_CAP}% | ${_ST} | ${_T}C | ${_V}V"
echo "健康 ${_H}% | 循环 ${_CYC_D}"
echo "------------------------------------"
echo "WebUI : KernelSU 模块页 -> 打开"
echo "菜单   : su -c \"sh $XBT/scripts/menu.sh\""
exit 0
