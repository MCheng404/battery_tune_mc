#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
BK=/sdcard/Download/xt_uninstall_backup_$(date +%Y%m%d_%H%M%S)

. $XBT/scripts/common.sh 2>/dev/null

mkdir -p "$BK" 2>/dev/null
cp -f "$XBT/config/settings.conf" "$BK/" 2>/dev/null
cp -f "$XBT/state/direct_current_defaults" "$BK/" 2>/dev/null
cp -f "$XBT/state/direct_control_defaults" "$BK/" 2>/dev/null
cp -f "$XBT/state/last_real_cycle.txt" "$BK/" 2>/dev/null
cp -f "$XBT/state/fv_default" "$BK/" 2>/dev/null
cp -f "$XBT/state/pss_initial" "$BK/" 2>/dev/null
cp -af "$XBT/state/cloud_quarantine" "$BK/" 2>/dev/null

cat > "$BK/还原说明.txt" 2>/dev/null <<'XEOF'
电池解容工具箱 · 卸载还原说明
============================
已自动还原：BAA挂载（已卸载并让系统重读原厂）、充电节点（电流/ctrl/温控，已按安装前快照写回）、
            smart_fv（已写回安装前值）、循环计数（如曾启用伪装）、云控隔离文件（已原样归还）、
            PSS低电锁容服务（已按安装前状态恢复）、模块各守护进程（已全部停止，含 FreePPS 进程）、
            FreePPS 整合（进程已停、数据目录已清、PD 验证节点已还原）。
不会自动回滚：DTBO 分区（解容镜像仍在设备里）。
  如需恢复原版 DTBO：
  ① 安装时的自动备份位于 /sdcard/Download/dtbo_backup/（dtbo_<槽位>_before_install_*.img）
  ② 重装本模块 →「DTBO 工具 → 从备份恢复/刷回」选择该镜像；或
  ③ 用 fastboot 刷入对应备份镜像。
建议：卸载后重启一次，让所有运行时节点彻底回到系统默认。
XEOF

sh $XBT/scripts/baa_ops.sh umount 2>/dev/null
setprop ctl.restart batteryantiaging 2>/dev/null

sh $XBT/scripts/fv_guard.sh stop 2>/dev/null
sh $XBT/scripts/cycle_guard.sh stop 2>/dev/null

command -v xbt_kill >/dev/null 2>&1 || . $XBT/scripts/common.sh 2>/dev/null
if ! command -v xbt_kill >/dev/null 2>&1; then

  xbt_kill() { for _p in $(pgrep -f "$1" 2>/dev/null); do kill -9 "$_p" 2>/dev/null; done; }
fi

xbt_kill 'battery_tune_mc/bin/freepps' 'battery_tune_mc/bin/freepps'
xbt_kill '^freepps$' 'freepps'

xbt_kill 'battery_tune_mc/scripts/charge_guard\.sh'   'battery_tune_mc/scripts/charge_guard.sh'
xbt_kill 'battery_tune_mc/scripts/cycle_guard\.sh'    'battery_tune_mc/scripts/cycle_guard.sh'
xbt_kill 'battery_tune_mc/scripts/cloud_guard\.sh'    'battery_tune_mc/scripts/cloud_guard.sh'
xbt_kill 'battery_tune_mc/scripts/diag_log\.sh'       'battery_tune_mc/scripts/diag_log.sh'
xbt_kill 'battery_tune_mc/scripts/fv_guard\.sh'       'battery_tune_mc/scripts/fv_guard.sh'
xbt_kill 'battery_tune_mc/scripts/fv_handler\.sh'     'battery_tune_mc/scripts/fv_handler.sh'
rm -f /data/local/tmp/xt_fv_guard.pid /data/local/tmp/xt_cycle_guard.pid 2>/dev/null
rm -f $XBT/state/thermal_restore_active 2>/dev/null

rm -f $XBT/state/cg_last_write_ts $XBT/state/cg_gap_log_ts 2>/dev/null

rm -f $XBT/state/inf_settled $XBT/state/inf_settle_ts $XBT/state/inf_settle_fail \
      $XBT/state/inf_selfcheck_ts $XBT/state/inf_node_capped 2>/dev/null

FP_DIR=/data/adb/modules/freepps
if [ -d "$FP_DIR" ]; then
  if [ -f "$FP_DIR/post-fs-data.sh" ] || [ -f "$FP_DIR/service.sh" ] || [ -f "$FP_DIR/module.prop" ]; then
    rm -f "$FP_DIR/free" 2>/dev/null
    log "uninstall: REAL FreePPS module detected -> kept intact (removed only our 'free' flag)"
  else
    rm -f "$FP_DIR/free" 2>/dev/null
    rmdir "$FP_DIR" 2>/dev/null
    log "uninstall: removed our own freepps state dir"
  fi
fi

#     /sys/class/qcom-battery/pd_verifed
#     /sys/class/Charging_Adapter/pd_adapter/usbpd_verifed

for _pv in /sys/class/qcom-battery/pd_verifed \
           /sys/class/Charging_Adapter/pd_adapter/usbpd_verifed \
           /sys/class/power_supply/usb/pd_verifed; do
  [ -e "$_pv" ] || continue
  chmod 664 "$_pv" 2>/dev/null
  if echo 0 > "$_pv" 2>/dev/null; then
    log "uninstall: $(basename "$_pv") -> 0"
  else
    log "uninstall: WARN $(basename "$_pv") write failed"
  fi
done

. $XBT/scripts/common.sh
restore_current_limit 2>/dev/null
restore_control_limit 2>/dev/null

_th_done=0
for _th in /sys/class/xm_power/charger/charger_thermal/wired_thermal_remove \
           /sys/class/xm_power/charger/charger_thermal/wireless_thermal_remove; do
  [ -e "$_th" ] || continue
  _cur=$(cat "$_th" 2>/dev/null)
  if [ "$_cur" = "1" ]; then
    chmod 664 "$_th" 2>/dev/null
    if echo 0 > "$_th" 2>/dev/null; then
      log "uninstall: $(basename "$_th") 1 -> 0 (release DT bypass)"
      _th_done=1
    else
      log "uninstall: WARN $(basename "$_th") write 0 failed (still=$_cur)"
    fi
  fi
done
if [ -s "$XBT/state/direct_control_defaults" ]; then
  if grep -qE 'thermal_remove\|1$' "$XBT/state/direct_control_defaults" 2>/dev/null; then
    cp -f "$XBT/state/direct_control_defaults" "$XBT/state/direct_control_defaults.polluted" 2>/dev/null
    log "uninstall: DETECTED polluted snapshot (thermal_remove|1) -> released to 0 (evidence .polluted)"
  fi
  [ "$_th_done" = "1" ] || log "uninstall: thermal_remove already 0 (snapshot kept as-is)"
else
  log "uninstall: no control snapshot -> thermal_remove forced 0"
fi

_fvd=$(cat "$XBT/state/fv_default" 2>/dev/null)
_fvsrc=$(cat "$XBT/state/fv_default_src" 2>/dev/null)
case "$_fvd" in
  ''|*[!0-9]*) ;;
  *)

    if [ "$_fvd" = "0" ] && [ "$_fvsrc" != "stock" ]; then
      cp -f "$XBT/state/fv_default" "$XBT/state/fv_default.polluted" 2>/dev/null
      log "uninstall: DETECTED polluted fv_default=0 (src=${_fvsrc:-legacy-none}) -> restoring factory 40mV (evidence .polluted)"
      _fvd=40
      _fvsrc="repaired"
    fi
    if [ -e "$FV_NODE" ]; then
      if echo "$_fvd" > "$FV_NODE" 2>/dev/null; then
        log "uninstall: smart_fv restored -> $_fvd (source=${_fvsrc:-?})"
      else
        log "uninstall: WARN smart_fv restore failed (target=$_fvd)"
      fi
    fi
    ;;
esac

#

_cycle_target() {
  _t=""
  for _s in "$(cat "$CYCLE_REAL_NODE" 2>/dev/null)" \
            "$(cat "$CYCLE_REAL_FILE" 2>/dev/null)" \
            "$(cat "${CYCLE_NODE:-/sys/class/xm_power/fg_master/cyclecount}" 2>/dev/null)" \
            "$(cat "${CYCLE_NODE2:-/sys/class/power_supply/battery/cycle_count}" 2>/dev/null)"; do
    case "$_s" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$_t" ] || [ "$_s" -gt "$_t" ] 2>/dev/null; then _t="$_s"; fi
  done
  echo "$_t"
}
_cf=$(cfg_get cycle_fake "")
_tgt=$(_cycle_target)
if [ -z "$_tgt" ]; then
  log "uninstall: cycle restore skipped (no usable real value found)"
else
  log "uninstall: cycle real target = $_tgt (qmax=$(cat "$CYCLE_REAL_NODE" 2>/dev/null) file=$(cat "$CYCLE_REAL_FILE" 2>/dev/null) fake_cfg=${_cf:-none})"
  for _cn in "${CYCLE_NODE:-/sys/class/xm_power/fg_master/cyclecount}" \
             "${CYCLE_NODE2:-/sys/class/power_supply/battery/cycle_count}"; do
    [ -e "$_cn" ] || continue
    _cur=$(cat "$_cn" 2>/dev/null)
    case "$_cur" in ''|*[!0-9]*) continue ;; esac
    if [ "$_cur" = "$_tgt" ]; then
      continue
    fi
    if [ -n "$_cf" ] && [ "$_cur" = "$_cf" ]; then
      :
    elif [ "$_cur" -gt "$_tgt" ] 2>/dev/null; then
      log "uninstall: $(basename "$_cn") kept at $_cur (> target $_tgt, never downgrade)"
      continue
    fi
    chmod 666 "$_cn" 2>/dev/null
    if echo "$_tgt" > "$_cn" 2>/dev/null; then
      log "uninstall: $(basename "$_cn") $_cur -> $_tgt"
    else
      log "uninstall: $(basename "$_cn") restore FAILED (readonly?)"
    fi
  done
fi

QD="$XBT/state/cloud_quarantine"
if [ -d "$QD" ]; then
  for f in "$QD"/*; do
    [ -e "$f" ] || continue
    _b=$(basename "$f")
    case "$_b" in _sources.log) continue ;; esac

    _src=$(grep -F "${_b}|" "$QD/_sources.log" 2>/dev/null | tail -n 1 | cut -d'|' -f2-)
    if [ -z "$_src" ]; then
      _ts=${_b%%__*}
      _src=$(grep -F "${_ts}|" "$QD/_sources.log" 2>/dev/null | tail -n 1 | cut -d'|' -f2-)
    fi

    _orig=$(echo "$_b" | sed -E 's/^[0-9]{8}_[0-9]{6}__([0-9]+__)?//')
    if [ -n "$_src" ] && [ -d "$(dirname "$_src")" ] && [ ! -e "$_src" ]; then
      mv "$f" "$_src" 2>/dev/null && { log "uninstall: cloud file returned -> $_src"; continue; }
    fi
    for d in /mnt/vendor/persist/charger/batteryantiaging/cloud_config \
             /data/vendor/batteryantiaging/cloud_config; do
      if [ -d "$d" ]; then
        mv "$f" "$d/$_orig" 2>/dev/null && { log "uninstall: cloud file returned -> $d/$_orig"; break; }
      fi
    done
  done
fi

_pss_made=$(cat "$XBT/state/pss_disabled_by_module" 2>/dev/null)
_pi=$(cat "$XBT/state/pss_initial" 2>/dev/null)
PSS_RESTORE=com.miui.securitycenter/com.miui.powercenter.provider.PowerSaveService
if [ "$_pss_made" = "1" ]; then
  pm enable "$PSS_RESTORE" 2>/dev/null
  log "uninstall: PSS re-enabled (was disabled by module -> restores battery health UI)"
  echo "enabled" > "$XBT/state/pss_initial" 2>/dev/null
elif [ "$_pi" = "disabled" ]; then
  log "uninstall: PSS kept as-is (was disabled before install, not by module)"
else
  pm enable "$PSS_RESTORE" 2>/dev/null
  log "uninstall: PSS re-enabled -> battery health UI restored"
fi

#        su -c 'sh /data/adb/modules/battery_tune_mc/scripts/dtbo.sh list'

_bkdir=$(cfg_get backup_dir "/sdcard/Download/dtbo_backup")

_dtbo_state="无法判断（dev_code/镜像缺失）"
_dtbo_slot=""
_devc0=$(cfg_get dev_code "")

_mine0=""
_dtbo_choice0=$(cat "$XBT/state/dtbo_choice" 2>/dev/null)
_hz0=$(echo "$_dtbo_choice0" | sed -n 's/^[a-z]*-_\([0-9]*\)$/\1/p')
case "$_hz0" in
  120|132|144|156|165)
    [ -f "$XBT/dtbo/${_hz0}hz.dtb" ] && _mine0="$XBT/dtbo/${_hz0}hz.dtb" ;;
esac
if [ -n "$_devc0" ] && [ -n "$_mine0" ]; then
  _pad0=/data/local/tmp/dtbo_uninst_build.img
  _dtbo_state="非本模块镜像（原厂/他版，无需处理）"
  for _s0 in a b; do
    _p0=/dev/block/by-name/dtbo_$_s0
    [ -e "$_p0" ] || continue
    _dsz0=$(blockdev --getsize64 "$_p0" 2>/dev/null)
    [ -n "$_dsz0" ] || continue
    _mh0=""
    rm -f "$_pad0" 2>/dev/null
    if sh "$XBT/scripts/build_dtbo.sh" "$_mine0" "$_pad0" "$_dsz0" 2>/dev/null; then
      _mh0=$(sha256sum "$_pad0" 2>/dev/null | awk '{print $1}')
    fi
    _c0=$(dd if="$_p0" bs=1M 2>/dev/null | sha256sum | awk '{print $1}')
    if [ -n "$_mh0" ] && [ "$_c0" = "$_mh0" ]; then
      _dtbo_state="仍是解容版（模块写的，未还原）"
      _dtbo_slot="$_s0"
      log "uninstall: DTBO 检测 —— slot $_s0 仍是本模块镜像"
      break
    fi
  done
  rm -f "$_pad0" 2>/dev/null
fi

log "uninstall: done (state backup at $BK)"
cp -f /data/local/tmp/xt_toolbox.log "$BK/xt_toolbox.log" 2>/dev/null
cp -f /data/local/tmp/xt_toolbox.log.rot "$BK/xt_toolbox.log.rot" 2>/dev/null

rm -f /data/local/tmp/xt_toolbox.log /data/local/tmp/xt_toolbox.log.rot 2>/dev/null
rm -f /data/local/tmp/xt_restore_list.txt /data/local/tmp/dtbo_pad_install.img 2>/dev/null
rm -f /data/local/tmp/dtbo_pad.img /data/local/tmp/xt_dtbo_list.txt 2>/dev/null
rm -f /data/local/tmp/xt_charge_guard.pid /data/local/tmp/xt_cloud_guard.pid \
      /data/local/tmp/xt_diag_log.pid 2>/dev/null
rm -f /sdcard/xt_toolbox.log 2>/dev/null

{
  echo ""
  echo "===== 卸载残留检查 ====="
  echo "[DTBO] $_dtbo_state"
  if [ -n "$_dtbo_slot" ]; then
    echo "       槽位: dtbo_$_dtbo_slot"
    echo "       ⚠ DTBO 是唯一需要重启才生效的项；要还原原厂请手动执行："
    echo "         su -c 'sh /data/adb/modules/battery_tune_mc/scripts/dtbo.sh list'"
    echo "         su -c 'sh /data/adb/modules/battery_tune_mc/scripts/dtbo.sh flash <备份文件>'"
    echo "         （备份命名 dtbo_<槽>_before_install_<时间>.img，在 $_bkdir）"
    echo "       ⚠ 注意：备份里【较早的那份】才是原厂；较晚的可能是上一版模块的魔改镜像。"
    echo "         判断方法：文件里模块镜像长度(616593B)之后若全为零 = 那次刷入是补零写"
    echo "         的魔改镜像；有非零数据 = 完整原厂镜像。"
  fi
  echo "[BAA]  $(sh $XBT/scripts/baa_ops.sh check 2>/dev/null | head -n 1)"
  echo "[节点] pd_verifed=$(cat /sys/class/qcom-battery/pd_verifed 2>/dev/null)"
  echo "       verified=$(cat /sys/class/xm_power/typec/strategy_pd_auth/verified 2>/dev/null)"
  echo "       fake_pps_ptf=$(cat /sys/class/xm_power/charger/quick_charge/fake_pps_ptf 2>/dev/null)"
  echo "       wired_thermal_remove=$(cat /sys/class/xm_power/charger/charger_thermal/wired_thermal_remove 2>/dev/null)"
  echo "       smart_fv=$(cat /sys/class/xm_power/charger/smart_charge/smart_fv 2>/dev/null)"
  echo "[PSS]  $(pm list packages -d 2>/dev/null | grep -c PowerSaveService) 个 PowerSaveService 仍被禁用"
  echo "[文件] /data/adb/modules/freepps: $( [ -d /data/adb/modules/freepps ] && echo 存在 || echo 已清 )"
  echo "[提示] 建议重启一次，让所有运行时节点彻底回到系统默认"
} >> "$BK/卸载残留.txt" 2>/dev/null
cat "$BK/卸载残留.txt" 2>/dev/null

exit 0
