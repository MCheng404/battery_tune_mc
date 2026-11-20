#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
CONF=$XBT/config/settings.conf
LOG=/data/local/tmp/battery_tune_mc.log

DEV_CODE=$(grep -E '^dev_code=' "$CONF" 2>/dev/null | tail -n 1 | cut -d= -f2-)
case "$DEV_CODE" in
  haotian)  DEV_NAME="小米15 Pro" ;;
  *)

    DEV_CODE=unsupported
    DEV_NAME="未知机型（未支持）"
    ;;
esac

if [ "$DEV_CODE" = "unsupported" ]; then
  IS_UNSUPPORTED=1
else
  IS_UNSUPPORTED=0
fi

case "$DEV_CODE" in
  haotian) DEV_MAXW=90 ;;
  unsupported) DEV_MAXW=0 ;;
  *) DEV_MAXW=90 ;;
esac

# ============================================================================

# ============================================================================
xbt_clean_stuck_tr() {
  _killed=0
  for _tp in $(pgrep -x tr 2>/dev/null); do
    [ -r "/proc/$_tp/stat" ] || continue
    _ppid=$(awk '{print $4}' "/proc/$_tp/stat" 2>/dev/null)
    _cpu=$(awk '{print $14+$15}' "/proc/$_tp/stat" 2>/dev/null)
    case "$_ppid$_cpu" in ''|*[!0-9]*) continue ;; esac
    if [ "$_ppid" = "1" ] && [ "$_cpu" -ge 600 ]; then
      kill -9 "$_tp" 2>/dev/null && _killed=$((_killed + 1))
    fi
  done
  [ "$_killed" -gt 0 ] && log "xbt: 清理卡死 tr $_killed 个（孤儿+CPU>=600s）"
  return 0
}

case "$DEV_CODE" in
  haotian) DEF_THERMAL_CEIL=580 ;;
  unsupported) DEF_THERMAL_CEIL=580 ;;
  *) DEF_THERMAL_CEIL=580 ;;
esac

BAA_SRC=$XBT/baa/payload_BAA_config_$DEV_CODE.json
BAA_STOCK=$XBT/baa/stock_BAA_config_$DEV_CODE.json
BAA_TGT=/odm/etc/charger/BAA_config_$DEV_CODE.json
BAA_LABEL=u:object_r:batteryantiaging_cfg_file:s0
FV_NODE=/sys/class/xm_power/charger/smart_charge/smart_fv
PSS=com.miui.securitycenter/com.miui.powercenter.provider.PowerSaveService

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
hash_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

#   $XBT/state/*（last_real_cycle.txt / fv_default / direct_*_defaults …），

[ -d "$XBT/state" ] || mkdir -p "$XBT/state" 2>/dev/null

#

#

XBT_TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
  XBT_TIMEOUT="timeout"
elif [ -x /data/adb/ksu/bin/busybox ]; then
  XBT_TIMEOUT="/data/adb/ksu/bin/busybox timeout"
elif [ -x /data/adb/magisk/busybox ]; then
  XBT_TIMEOUT="/data/adb/magisk/busybox timeout"
elif command -v busybox >/dev/null 2>&1; then
  XBT_TIMEOUT="busybox timeout"
fi

_xbt_run() {

  _secs="$1"; shift
  if [ -n "$XBT_TIMEOUT" ]; then
    $XBT_TIMEOUT "$_secs" "$@"
  else
    "$@"
  fi
}

if [ -z "$XBT_TIMEOUT" ]; then
  timeout() { shift; "$@"; }
fi

xbt_pids() {
  _pat="$1"
  _lit="${2:-$1}"
  if command -v pgrep >/dev/null 2>&1; then
    for _pid in $(pgrep -f "$_pat" 2>/dev/null); do
      [ "$_pid" = "$$" ] && continue
      _cmd=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
      case "$_cmd" in *"$_lit"*) echo "$_pid" ;; esac
    done
    return 0
  fi
  for _p in /proc/[0-9]*; do
    _pid=${_p#/proc/}
    [ "$_pid" = "$$" ] && continue
    _cmd=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)
    case "$_cmd" in *"$_lit"*) echo "$_pid" ;; esac
  done
}

pid_alive() {
  _pid="$1"; _tok="$2"
  case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -d "/proc/$_pid" ] || return 1
  kill -0 "$_pid" 2>/dev/null || return 1
  [ -z "$_tok" ] && return 0
  _cmd=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
  case "$_cmd" in *"$_tok"*) return 0 ;; esac
  return 1
}
xbt_kill() {

  for _k in $(xbt_pids "$1" "$2"); do kill -9 "$_k" 2>/dev/null; done
}

CYCLE_NODE=/sys/class/xm_power/fg_master/cyclecount
CYCLE_NODE2=/sys/class/power_supply/battery/cycle_count
CYCLE_REAL_NODE=/sys/class/xm_power/fg_master/qmax_cyclecount
CYCLE_REAL_FILE=$XBT/state/last_real_cycle.txt

cycle_real_read() {
  _r=$(cat "$CYCLE_REAL_NODE" 2>/dev/null)
  case "$_r" in ''|*[!0-9]*) _r="" ;; esac
  if [ -z "$_r" ]; then
    _r=$(cat "$CYCLE_NODE" 2>/dev/null)
    case "$_r" in ''|*[!0-9]*) _r="" ;; esac
  fi
  echo "$_r"
}

cycle_real_capture() {
  _cur=$(cycle_real_read)
  [ -n "$_cur" ] || return 1
  _cf=$(cfg_get cycle_fake "")
  _old=$(cat "$CYCLE_REAL_FILE" 2>/dev/null)
  case "$_old" in ''|*[!0-9]*) _old="" ;; esac
  if [ -z "$_old" ]; then
    mkdir -p $XBT/state 2>/dev/null
    echo "$_cur" > "$CYCLE_REAL_FILE" 2>/dev/null
    log "cycle: real value captured $_cur (was empty)"
    return 0
  fi
  if [ -z "$_cf" ]; then

    if [ "$_cur" -gt "$_old" ]; then
      echo "$_cur" > "$CYCLE_REAL_FILE" 2>/dev/null
      log "cycle: real value updated $_old -> $_cur (no disguise)"
    fi
  else

    if [ "$_old" = "$_cf" ] && [ "$_cur" != "$_cf" ]; then
      echo "$_cur" > "$CYCLE_REAL_FILE" 2>/dev/null
      log "cycle: last_real was polluted by fake ($_cf) -> corrected to $_cur"
    fi
  fi
  return 0
}

cfg_get() {
  _k="$1"; _d="$2"
  case "$_k" in ''|*[!A-Za-z0-9_]*) printf '%s\n' "$_d"; return ;; esac
  [ -f "$CONF" ] || { printf '%s\n' "$_d"; return; }
  _v=$(awk -F= -v k="$_k" '{ if ($1==k) { v=$0; sub(/^[^=]*=/,"",v) } } END { if (v!="") print v }' "$CONF" 2>/dev/null)
  if [ -n "$_v" ]; then printf '%s\n' "$_v"; else printf '%s\n' "$_d"; fi
}

cfg_set() {
  _k="$1"; _v="$2"
  case "$_k" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  mkdir -p "$(dirname "$CONF")" "$XBT/state" 2>/dev/null

  # Serialize writers: concurrent WebUI toggles used to lose updates between
  # the read-modify-write of sed -i. mkdir is atomic on every Android fs.
  _lock="$XBT/state/.cfg.lock"
  _try=0
  while ! mkdir "$_lock" 2>/dev/null; do
    _try=$((_try + 1))
    [ "$_try" -ge 40 ] && { rm -rf "$_lock" 2>/dev/null; break; }
    sleep 0.05
  done
  trap 'rmdir "$_lock" 2>/dev/null' EXIT HUP INT TERM

  _tmp="$CONF.tmp.$$"
  if [ -f "$CONF" ]; then
    awk -F= -v k="$_k" -v v="$_v" '
      $1==k { if (!done) { print k"="v; done=1 } ; next }
      { print }
      END { if (!done) print k"="v }
    ' "$CONF" > "$_tmp" 2>/dev/null
  else
    printf '%s=%s\n' "$_k" "$_v" > "$_tmp" 2>/dev/null
  fi
  if [ -s "$_tmp" ]; then mv -f "$_tmp" "$CONF"; else rm -f "$_tmp"; fi
  rmdir "$_lock" 2>/dev/null
  trap - 0 1 2 15
}

DT_CEIL_PATHS="/proc/device-tree/soc/mca_strategy_quick_charge/temp_para1
/proc/device-tree/soc/mca_quick_charge_batt_para_gbl/temp_para1
/proc/device-tree/soc/mca_strategy_quick_wireless_class/temp_para1
/proc/device-tree/soc/mca_quick_wireless_batt_para_gbl/temp_para1"
detect_dt_thermal_ceil() {
  _f=""
  for _c in $DT_CEIL_PATHS; do
    [ -r "$_c" ] && { _f="$_c"; break; }
  done
  [ -n "$_f" ] || return 1
  _up=$(tr '\0' '\n' < "$_f" 2>/dev/null | awk '
    NF { a[++n]=$0 }
    END {
      cut=""
      for (i=2; i<=n-1; i++) {
        if (a[i]=="65535" && a[i+1]=="0") {
          if (a[i-1] ~ /^[0-9]+$/ && a[i-1]+0 > 0 && a[i-1]+0 < 200) cut=a[i-1]
        }
      }
      if (cut != "") printf "%d", (cut-1)*10
    }' 2>/dev/null)
  case "$_up" in ''|*[!0-9]*) return 1 ;; esac

  [ "$_up" -ge 400 ] 2>/dev/null && [ "$_up" -le 750 ] 2>/dev/null || return 1
  echo "$_up"
  return 0
}

THERMAL_CEIL=$(cfg_get thermal_ceil "$DEF_THERMAL_CEIL")
case "$THERMAL_CEIL" in
  ''|*[!0-9]*) THERMAL_CEIL="$DEF_THERMAL_CEIL" ;;
esac
[ "$THERMAL_CEIL" -gt 0 ] 2>/dev/null || THERMAL_CEIL="$DEF_THERMAL_CEIL"

if [ -z "$(grep -E '^thermal_ceil=' "$CONF" 2>/dev/null | tail -n 1 | cut -d= -f2-)" ]; then
  _dtc=$(detect_dt_thermal_ceil 2>/dev/null)
  case "$_dtc" in
    ''|*[!0-9]*) : ;;
    *)
      if [ "$_dtc" -ge 400 ] 2>/dev/null && [ "$_dtc" -le 750 ] 2>/dev/null; then
        THERMAL_CEIL="$_dtc"
      fi
      ;;
  esac
  unset _dtc
fi

THERMAL_HYST=${THERMAL_HYST:-30}
case "$THERMAL_HYST" in ''|*[!0-9]*) THERMAL_HYST=30 ;; esac
[ "$THERMAL_HYST" -ge 0 ] 2>/dev/null || THERMAL_HYST=30
[ "$THERMAL_HYST" -gt 200 ] 2>/dev/null && THERMAL_HYST=200
THERMAL_GATE_FILE=$XBT/state/thermal_gate

slot_letter() {
  _s=$(getprop ro.boot.slot_suffix)
  echo "${_s#_}"
}

baa_state() {

  _s=$(hash_of "$BAA_SRC"); _t=$(hash_of "$BAA_TGT")
  _l=$(stat -c '%C' "$BAA_TGT" 2>/dev/null)
  _sl=$(stat -c '%C' "$BAA_SRC" 2>/dev/null)

  if [ -n "$_s" ] && [ "$_s" = "$_t" ] && [ -n "$_l" ] &&
     { [ "$_l" = "$_sl" ] || [ "$_l" = "$BAA_LABEL" ]; }; then
    echo "active"
  else
    echo "inactive"
  fi
}

baa_state_cn() {
  _bs=$(baa_state)
  case "$_bs" in skipped) echo "跳过(系统BAA为空)" ;; *) echo "$_bs" ;; esac
}

pss_state() {
  _d=$(dumpsys package com.miui.securitycenter 2>/dev/null)
  _seg=$(echo "$_d" | sed -n '/disabledComponents:/,/enabledComponents:/p')
  case "$_seg" in
    *PowerSaveService*) echo "disabled" ;;
    *) echo "enabled" ;;
  esac
}

pss_guard_tick() {
  [ "$(cfg_get pss_disable 1)" = "1" ] || return 0
  _low=$(cfg_get pss_low_soc 0)
  case "$_low" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_low" -gt 0 ] 2>/dev/null || return 0
  _hys=$(cfg_get pss_low_hyst 5)
  case "$_hys" in ''|*[!0-9]*) _hys=5 ;; esac
  _soc=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  case "$_soc" in ''|*[!0-9]*) return 0 ;; esac
  _pd=$(cat "$XBT/state/pss_dynamic" 2>/dev/null)
  if [ "$_soc" -le "$_low" ]; then

    [ "$_pd" = "disabled" ] && return 0
    pm disable "$PSS" >/dev/null 2>&1
    echo 1 > "$XBT/state/pss_disabled_by_module" 2>/dev/null
    echo disabled > "$XBT/state/pss_dynamic" 2>/dev/null
    log "pss_dynamic: SOC=${_soc}% <= ${_low}% → PSS 禁用（防低电量锁容）"
  elif [ "$_soc" -ge "$((_low + _hys))" ]; then

    [ "$_pd" = "enabled" ] && return 0
    pm enable "$PSS" >/dev/null 2>&1
    rm -f "$XBT/state/pss_disabled_by_module" 2>/dev/null
    echo enabled > "$XBT/state/pss_dynamic" 2>/dev/null
    log "pss_dynamic: SOC=${_soc}% >= $((_low + _hys))% → PSS 启用（恢复电池健康度显示）"
  fi
  return 0
}

power_now() { echo inf; }

DIRECT_WIRED=/sys/class/xm_power/charger/charger_thermal/wired_chg_curr
DIRECT_WIRED2=/sys/class/xm_power/charger/charger_thermal/wired_chg_curr2
DIRECT_WIRELESS=/sys/class/xm_power/charger/charger_thermal/wireless_chg_curr
DIRECT_WIRED_CTRL=/sys/class/xm_power/charger/charger_thermal/wired_ctrl_limit
DIRECT_WIRELESS_CTRL=/sys/class/xm_power/charger/charger_thermal/wireless_ctrl_limit
DIRECT_WIRELESS_MAG_CTRL=/sys/class/xm_power/charger/charger_thermal/wireless_mag_ctrl_limit
DIRECT_WIRED_THERMAL_REMOVE=/sys/class/xm_power/charger/charger_thermal/wired_thermal_remove
DIRECT_WIRELESS_THERMAL_REMOVE=/sys/class/xm_power/charger/charger_thermal/wireless_thermal_remove

direct_current_nodes() {
  _out=0
  for _p in "$DIRECT_WIRED" "$DIRECT_WIRED2" "$DIRECT_WIRELESS"; do
    [ -e "$_p" ] || continue
    if [ -w "$_p" ]; then echo "$_p"; _out=1; fi
  done

  [ "$_out" = "1" ] && return 0

  for _p in \
    /sys/class/power_supply/main/constant_charge_current_max \
    /sys/class/power_supply/battery/constant_charge_current_max \
    /sys/class/power_supply/battery/constant_charge_current
  do
    [ -e "$_p" ] && echo "$_p"
  done
}

current_node() {
  direct_current_nodes | head -n 1
}

direct_set_current_ma() {
  _value="$1"
  _th="${2:-}"
  _lv="${3:-}"
  case "$_value" in ''|*[!0-9]*) return 1 ;; esac
  case "$_th" in 0|1) ;; *) _th=$(thermal_target) ;; esac

  if [ -z "$_lv" ]; then
    _lv=0
  fi
  case "$_lv" in ''|*[!0-9]*) _lv=0 ;; esac

  _ok=0
  for _p in $(direct_current_nodes); do
    [ -n "$_p" ] || continue
    case "$_p" in
      *wireless*) _raw=$_value ;;
      *)          _raw=$((_value * 1000)) ;;
    esac
    chmod 664 "$_p" 2>/dev/null
    if echo "$_raw" > "$_p" 2>>"$LOG"; then
      _ok=1
    else
      log "direct: write failed node=$_p value=${_raw}"
    fi
  done
  [ "$_ok" = "1" ] || return 1

  _ctrl_ok=0
  for _p in $(direct_limit_nodes); do
    [ -e "$_p" ] || continue
    chmod 664 "$_p" 2>/dev/null
    if echo "$_lv" > "$_p" 2>>"$LOG"; then
      _ctrl_ok=1
    else
      log "direct: ctrl write failed node=$_p value=$_lv"
    fi
  done

  for _p in $(direct_thermal_remove_nodes); do
    [ -e "$_p" ] || continue
    chmod 664 "$_p" 2>/dev/null
    echo "$_th" > "$_p" 2>>"$LOG" || _ctrl_ok=0
  done

  direct_record_applied "$_value"

  if [ -n "$(direct_control_nodes)" ]; then
    [ "$_ctrl_ok" = "1" ]
  else
    true
  fi
}

direct_control_nodes() {
  direct_limit_nodes
  direct_thermal_remove_nodes
}

direct_limit_nodes() {
  for _p in \
    "$DIRECT_WIRED_CTRL" \
    "$DIRECT_WIRELESS_CTRL" \
    "$DIRECT_WIRELESS_MAG_CTRL"
  do
    [ -e "$_p" ] && echo "$_p"
  done
}

direct_thermal_remove_nodes() {
  for _p in "$DIRECT_WIRED_THERMAL_REMOVE" "$DIRECT_WIRELESS_THERMAL_REMOVE"; do
    [ -e "$_p" ] && echo "$_p"
  done
}

#

thermal_target() {
  _t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
  case "$_t" in
    ''|*[!0-9-]*) echo 1; return ;;
  esac
  _on=${THERMAL_CEIL:-560}
  _off=$((_on - ${THERMAL_HYST:-30}))

  _st=$(cat "$THERMAL_GATE_FILE" 2>/dev/null)
  if [ "$_t" -ge "$_on" ] 2>/dev/null; then
    [ "$_st" = "0" ] || echo 0 > "$THERMAL_GATE_FILE" 2>/dev/null
    echo 0
    return
  fi
  if [ "$_st" = "0" ] && [ "$_t" -gt "$_off" ] 2>/dev/null; then
    echo 0
    return
  fi
  [ "$_st" = "0" ] && echo 1 > "$THERMAL_GATE_FILE" 2>/dev/null
  echo 1
}

direct_set_thermal() {
  _v="${1:-$(thermal_target)}"
  case "$_v" in 0|1) ;; *) _v=1 ;; esac
  for _p in $(direct_thermal_remove_nodes); do
    chmod 664 "$_p" 2>/dev/null
    echo "$_v" > "$_p" 2>/dev/null
  done
}

dt_curr_cap_ma() {
  _f=/proc/device-tree/soc/mca_strategy_quick_charge/div_max_curr
  [ -e "$_f" ] || { echo ""; return; }
  od -An -tu1 -v "$_f" 2>/dev/null | awk '
    { for(i=1;i<=NF;i++) a[++n]=$i }
    END{
      if(n<4){print ""; exit}
      max=0
      for(i=1;i+3<=n;i+=4){
        v=a[i]*16777216+a[i+1]*65536+a[i+2]*256+a[i+3]
        if(v>max) max=v
      }
      print max
    }'
}

tier_target_ma() {
  _w=""
  case "$1" in
    inf)

      _cap=20000
      _dc=$(dt_curr_cap_ma 2>/dev/null)
      case "$_dc" in ''|*[!0-9]*) _dc="" ;; esac
      [ -n "$_dc" ] && [ "$_dc" -gt 0 ] && [ "$_dc" -lt "$_cap" ] && _cap="$_dc"
      _om=$(cfg_get apl_max_ma "")
      case "$_om" in ''|*[!0-9]*) ;; *)
        [ "$_om" -gt 0 ] && [ "$_om" -lt "$_cap" ] && _cap="$_om" ;; esac
      _at=$(cat "$XBT/state/apl_target_ma" 2>/dev/null)
      case "$_at" in ''|*[!0-9]*) _at="" ;; esac
      if [ -n "$_at" ] && [ "$_at" -ge 2000 ]; then
        [ "$_at" -gt "$_cap" ] && _at="$_cap"
        echo "$_at"
      else
        echo "$_cap"
      fi
      return ;;

    *)    echo ""; return ;;
  esac
}

tw_limit_c() {
  _v=$(cfg_get tw_limit 42)
  case "$_v" in ''|*[!0-9]*) _v=42 ;; esac
  [ "$_v" -lt 30 ] 2>/dev/null && _v=30
  [ "$_v" -gt 55 ] 2>/dev/null && _v=55
  echo "$_v"
}

tw_resume_c() {
  _v=$(cfg_get tw_resume 38)
  case "$_v" in ''|*[!0-9]*) _v=38 ;; esac
  _l=$(tw_limit_c)
  [ "$_v" -lt 25 ] 2>/dev/null && _v=25
  [ "$_v" -ge "$_l" ] 2>/dev/null && _v=$((_l - 1))
  echo "$_v"
}

tw_power_w() {
  _v=$(cfg_get tw_power_w 25)
  case "$_v" in ''|*[!0-9]*) _v=25 ;; esac
  [ "$_v" -lt 5 ] 2>/dev/null && _v=5
  [ "$_v" -gt 60 ] 2>/dev/null && _v=60
  echo "$_v"
}

dyn_mode() {
  _m=$(cfg_get dyn_mode balanced)
  case "$_m" in gentle|balanced|aggressive|berserk) echo "$_m" ;; *) echo balanced ;; esac
}

policy_on() {
  [ "$(cfg_get tw_enable 0)" = "1" ] && return 0
  [ "$(cfg_get dyn_enable 0)" = "1" ] && return 0
  return 1
}

policy_suspend_set() {
  _v="$1"
  _st=$(cat "$XBT/state/policy_suspended" 2>/dev/null)
  case "$_v" in 1) ;; *) _v=0 ;; esac
  [ "$_v" = "1" ] && [ "$_st" = "1" ] && return 0
  [ "$_v" = "0" ] && [ "$_st" = "0" ] && return 0
  service call vendor.xiaomi.hardware.micharge.IMiCharge/default 42 s16 "$_v" >/dev/null 2>&1 || return 1
  echo "$_v" > "$XBT/state/policy_suspended" 2>/dev/null
  return 0
}

policy_cut_want() {
  _pcut=0
  if [ "$(cfg_get tw_enable 0)" = "1" ] && [ "$(cat "$XBT/state/tw_active" 2>/dev/null)" = "1" ]; then
    _pcut=1
  fi
  if [ "$(cfg_get dyn_enable 0)" = "1" ]; then
    case "$(dyn_mode)" in
      gentle)     _ts=36; _th=42; _ss=70; _sh=90 ;;
      aggressive) _ts=42; _th=48; _ss=85; _sh=95 ;;
      berserk)    _ts=45; _th=52; _ss=90; _sh=98 ;;
      *)          _ts=39; _th=45; _ss=78; _sh=92 ;;
    esac
    _t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    _soc=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    case "$_t" in ''|*[!0-9-]*) _t=350 ;; esac
    case "$_soc" in ''|*[!0-9]*) _soc=50 ;; esac
    if [ "$(cat "$XBT/state/dyn_cut" 2>/dev/null)" = "1" ]; then
      if [ "$_t" -le $((_th * 10 - 20)) ] 2>/dev/null && [ "$_soc" -le $((_sh - 3)) ] 2>/dev/null; then
        rm -f "$XBT/state/dyn_cut" 2>/dev/null
      else
        _pcut=1
      fi
    elif [ "$_t" -ge $((_th * 10)) ] 2>/dev/null || [ "$_soc" -ge "$_sh" ] 2>/dev/null; then
      echo 1 > "$XBT/state/dyn_cut" 2>/dev/null
      _pcut=1
    fi
  else
    rm -f "$XBT/state/dyn_cut" 2>/dev/null
  fi
  [ "$_pcut" = "1" ]
}

tw_update_latch() {
  [ "$(cfg_get tw_enable 0)" = "1" ] || {
    rm -f "$XBT/state/tw_active" "$XBT/state/tw_changed" 2>/dev/null
    return 0
  }
  _t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
  case "$_t" in ''|*[!0-9-]*) return 0 ;; esac
  _on=$(( $(tw_limit_c) * 10 ))
  _off=$(( $(tw_resume_c) * 10 ))
  _st=$(cat "$XBT/state/tw_active" 2>/dev/null)
  case "$_st" in 1) ;; *) _st=0 ;; esac
  if [ "$_t" -ge "$_on" ] 2>/dev/null; then
    _new=1
  elif [ "$_t" -le "$_off" ] 2>/dev/null; then
    _new=0
  else
    _new=$_st
  fi
  if [ "$_new" != "$_st" ]; then
    echo "$_new" > "$XBT/state/tw_active" 2>/dev/null
    echo 1 > "$XBT/state/tw_changed" 2>/dev/null
  fi
}

policy_target_ma() {
  _base=$(tier_target_ma inf)
  case "$_base" in ''|*[!0-9]*) echo ""; return ;; esac
  _v="${1:-$(read_voltage_uv)}"
  case "$_v" in ''|*[!0-9]*) _v=4300000 ;; esac
  [ "$_v" -lt 3000000 ] 2>/dev/null && _v=4300000
  [ "$_v" -gt 5000000 ] 2>/dev/null && _v=4300000
  _desired=$_base

  if [ "$(cfg_get dyn_enable 0)" = "1" ]; then
    _m=$(dyn_mode)
    case "$_m" in
      gentle)     _mw=45; _ts=36; _th=42; _mp=55; _ss=70; _sh=90; _sm=50; _fl=1500 ;;
      aggressive) _mw=75; _ts=42; _th=48; _mp=75; _ss=85; _sh=95; _sm=70; _fl=3500 ;;
      berserk)    _mw=90; _ts=45; _th=52; _mp=85; _ss=90; _sh=98; _sm=80; _fl=5000 ;;
      *)          _mw=60; _ts=39; _th=45; _mp=65; _ss=78; _sh=92; _sm=60; _fl=2500 ;;
    esac
    _cap=$((_mw * 1000000000 / _v))
    [ "$_cap" -lt "$_desired" ] && _desired=$_cap

    _t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    case "$_t" in ''|*[!0-9-]*) _t=350 ;; esac
    _tp=100
    if [ "$_t" -ge $((_th * 10)) ] 2>/dev/null; then
      _tp=$_mp
    elif [ "$_t" -gt $((_ts * 10)) ] 2>/dev/null; then
      _span=$(((_th - _ts) * 10))
      _pos=$((_t - _ts * 10))
      _tp=$((100 - (100 - _mp) * _pos / _span))
    fi

    _soc=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    case "$_soc" in ''|*[!0-9]*) _soc=50 ;; esac
    _sp=100
    if [ "$_soc" -ge "$_sh" ] 2>/dev/null; then
      _sp=$_sm
    elif [ "$_soc" -gt "$_ss" ] 2>/dev/null; then
      _sp=$((100 - (100 - _sm) * (_soc - _ss) / (_sh - _ss)))
    fi

    _vp=100
    if [ "$_v" -ge 4500000 ] 2>/dev/null; then
      _vp=60
    elif [ "$_v" -gt 4400000 ] 2>/dev/null; then
      _vp=$((100 - 40 * (_v - 4400000) / 100000))
    fi

    _pct=$((_tp * _sp / 100))
    _pct=$((_pct * _vp / 100))
    _desired=$((_base * _pct / 100))
    [ "$_desired" -lt "$_fl" ] && _desired=$_fl
    [ "$_desired" -gt "$_base" ] && _desired=$_base
  fi

  if [ "$(cfg_get tw_enable 0)" = "1" ] && [ "$(cat "$XBT/state/tw_active" 2>/dev/null)" = "1" ]; then
    _w=$(tw_power_w)
    _wma=$((_w * 1000000000 / _v))
    [ "$_wma" -lt "$_desired" ] && _desired=$_wma
  fi

  [ "$_desired" -lt 1000 ] 2>/dev/null && _desired=1000
  [ "$_desired" -gt "$_base" ] 2>/dev/null && _desired=$_base
  echo "$_desired"
}

direct_tier_is_applied() {  _tier="$1"
  _snap="$XBT/state/direct_applied"

  _ma=$(tier_target_ma "$_tier")
  [ -n "$_ma" ] || return 1
  [ -s "$_snap" ] || return 1
  _rec=$(grep -F 'TARGET|' "$_snap" 2>/dev/null | head -n 1 | cut -d'|' -f2)
  case "$_rec$_ma" in *[!0-9]*) return 1 ;; esac

  _dtol=$((_ma / 25)); [ "$_dtol" -lt 120 ] && _dtol=120
  _dd=$((_rec - _ma)); [ "$_dd" -lt 0 ] && _dd=$((0 - _dd))
  [ "$_dd" -le "$_dtol" ] || return 1

  _want_th=$(thermal_target)
  for _p in $(direct_thermal_remove_nodes); do
    [ "$(cat "$_p" 2>/dev/null)" = "$_want_th" ] || return 1
  done

  for _p in $(direct_limit_nodes); do
    [ -e "$_p" ] || continue
    [ "$(cat "$_p" 2>/dev/null)" = "0" ] || return 1
  done
  return 0
}

direct_node_read_ma() {
  _node="$1"
  [ -n "$_node" ] || { echo ""; return; }
  _raw=$(cat "$_node" 2>/dev/null)
  case "$_raw" in ''|*[!0-9]*) echo ""; return ;; esac
  case "$_node" in
    "$DIRECT_WIRELESS") echo "$_raw" ;;
    *) echo $((_raw / 1000)) ;;
  esac
}

direct_node_read_ma_all() {

  #

  _min=""
  _min_all=""
  for _p in $(direct_current_nodes); do
    [ -n "$_p" ] || continue
    _v=$(direct_node_read_ma "$_p" 2>/dev/null)
    case "$_v" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$_min_all" ] || [ "$_v" -lt "$_min_all" ]; then _min_all="$_v"; fi
    case "$_p" in
      *wireless*) continue ;;
    esac
    if [ -z "$_min" ] || [ "$_v" -lt "$_min" ]; then _min="$_v"; fi
  done
  if [ -n "$_min" ]; then echo "$_min"
  elif [ -n "$_min_all" ]; then echo "$_min_all"
  else echo ""
  fi
}

direct_node_default_raw() {
  _node="$1"
  _raw=$(cat "$_node" 2>/dev/null)
  case "$_raw" in ''|*[!0-9]*) return 1 ;; esac
  case "$_node" in
    "$DIRECT_WIRELESS") echo $((_raw * 1000)) ;;
    *) echo "$_raw" ;;
  esac
}

direct_record_applied() {
  _t="${1:-}"
  mkdir -p "$XBT/state" 2>/dev/null
  _snap="$XBT/state/direct_applied"
  {
    echo "TARGET|${_t}"
    for _p in $(direct_current_nodes); do
      [ -n "$_p" ] || continue
      _raw=$(direct_node_default_raw "$_p" 2>/dev/null)
      [ -n "$_raw" ] && echo "NODE|${_p}|${_raw}"
    done
    for _p in $(direct_thermal_remove_nodes); do
      echo "THERM|${_p}|$(cat "$_p" 2>/dev/null)"
    done
    for _p in $(direct_limit_nodes); do
      echo "CTRL|${_p}|$(cat "$_p" 2>/dev/null)"
    done
  } > "$_snap" 2>/dev/null
}

read_voltage_uv() {
  for _p in \
    /sys/class/power_supply/battery/voltage_now \
    /sys/class/power_supply/main/voltage_now \
    /sys/class/power_supply/usb/voltage_now
  do
    _v=$(cat "$_p" 2>/dev/null)
    case "$_v" in ''|*[!0-9]*) continue ;; esac
    [ "$_v" -gt 1000 ] 2>/dev/null || continue
    if [ "$_v" -lt 100000 ] 2>/dev/null; then _v=$((_v * 1000)); fi
    echo "$_v"
    return 0
  done
  echo ""
}

target_current_ma() {
  if policy_on; then
    policy_target_ma "${1:-}"
  else
    tier_target_ma "$(power_now)"
  fi
}

quantize_current_ma() {
  case "$1" in
    ''|*[!0-9]*) echo ""; return ;;
  esac
  awk -v r="$1" 'BEGIN {
    q = int((r + 50) / 100) * 100;
    if (q < 500) q = 500;
    if (q > 12000) q = 12000;
    printf "%d", q;
  }'
}

snapshot_current_limit() {
  mkdir -p "$XBT/state" 2>/dev/null
  _snap="$XBT/state/direct_current_defaults"

  _old_node=$(cat "$XBT/state/current_limit_node" 2>/dev/null)
  _old_raw=$(cat "$XBT/state/current_limit_default" 2>/dev/null)
  case "$_old_raw" in
    ''|*[!0-9]*) ;;
    *)
      [ -n "$_old_node" ] && ! grep -qF "${_old_node}|" "$_snap" 2>/dev/null &&
        echo "${_old_node}|${_old_raw}" >> "$_snap"
      ;;
  esac

  for _p in $(direct_current_nodes); do
    [ -n "$_p" ] || continue
    grep -qF "${_p}|" "$_snap" 2>/dev/null && continue
    _raw=$(direct_node_default_raw "$_p") || continue
    case "$_raw" in ''|*[!0-9]*|0) continue ;; esac
    [ "$_raw" -gt 0 ] 2>/dev/null || continue
    echo "${_p}|${_raw}" >> "$_snap"
  done
  return 0
}

snapshot_control_limit() {
  mkdir -p "$XBT/state" 2>/dev/null
  _snap="$XBT/state/direct_control_defaults"

  #

  if [ -s "$_snap" ] && grep -qE 'thermal_remove\|1$' "$_snap" 2>/dev/null; then
    [ -f "$_snap.polluted" ] || cp -f "$_snap" "$_snap.polluted" 2>/dev/null
    _fix="$_snap.fix.$$"
    : > "$_fix" 2>/dev/null
    while IFS= read -r _ln; do
      case "$_ln" in
        *'|thermal_remove|1') printf '%s\n' "${_ln%1}0" >> "$_fix" ;;
        *)                    printf '%s\n' "$_ln"      >> "$_fix" ;;
      esac
    done < "$_snap"
    if [ -s "$_fix" ] && ! grep -qE 'thermal_remove\|1$' "$_fix" 2>/dev/null; then
      mv -f "$_fix" "$_snap" 2>/dev/null
      log "snapshot: repaired polluted thermal_remove|1 -> 0 (evidence kept as .polluted)"
    else
      rm -f "$_fix" 2>/dev/null
      log "snapshot: ⚠ polluted snapshot repair FAILED（保留原文件，卸载时请人工核对 thermal_remove）"
    fi
  fi

  for _p in $(direct_control_nodes); do
    [ -n "$_p" ] || continue
    grep -qF "${_p}|" "$_snap" 2>/dev/null && continue
    _raw=$(cat "$_p" 2>/dev/null)
    case "$_raw" in ''|*[!0-9]*) continue ;; esac
    echo "${_p}|${_raw}" >> "$_snap"
  done
  return 0
}

restore_current_limit() {
  _snap="$XBT/state/direct_current_defaults"
  [ -s "$_snap" ] || return 1
  _ok=0
  while IFS='|' read -r _p _raw; do
    [ -n "$_p" ] || continue
    case "$_raw" in ''|*[!0-9]*) continue ;; esac
    if [ -e "$_p" ]; then
      chmod 664 "$_p" 2>/dev/null
      [ -w "$_p" ] || continue
      echo "$_raw" > "$_p" 2>>"$LOG" && _ok=1
    fi
  done < "$_snap"
  [ "$_ok" = "1" ]
}

restore_control_limit() {
  _snap="$XBT/state/direct_control_defaults"
  [ -s "$_snap" ] || return 1
  _ok=0
  while IFS='|' read -r _p _raw; do
    [ -n "$_p" ] || continue
    case "$_raw" in ''|*[!0-9]*) continue ;; esac
    if [ -e "$_p" ]; then
      chmod 664 "$_p" 2>/dev/null
      [ -w "$_p" ] || continue
      echo "$_raw" > "$_p" 2>>"$LOG" && _ok=1
    fi
  done < "$_snap"
  [ "$_ok" = "1" ]
}

cloud_line() {
  _cg=$(cfg_get cloud_guard 1)
  if [ "$_cg" = "1" ]; then _s="开"; else _s="关"; fi
  _f=$XBT/state/cloud_guard.state
  _lc="-"; _rl="待巡检"; _bt=0
  if [ -f "$_f" ]; then
    _lc=$(grep '^last_check=' "$_f" 2>/dev/null | tail -n 1 | cut -d= -f2)
    _r=$(grep '^last_result=' "$_f" 2>/dev/null | tail -n 1 | cut -d= -f2)
    _bt=$(grep '^blocked_total=' "$_f" 2>/dev/null | tail -n 1 | cut -d= -f2)
    case "$_r" in
      clean) _rl="正常" ;;
      blocked) _rl="有拦截" ;;
      off) _rl="未启用" ;;
      *) _rl="待巡检" ;;
    esac
  fi
  [ -n "$_lc" ] || _lc="-"
  [ -n "$_bt" ] || _bt=0
  echo "云控屏蔽 : ${_s} | 巡检:${_lc} ${_rl} | 拦截:${_bt}"
}

sub_cloud() {
  echo
  echo "[云控屏蔽 - BAA云端下发防护]"
  sh $XBT/scripts/cloud_guard.sh status
  echo
  echo "  1) 开启屏蔽 (v1h·服务跳过云端配置)"
  echo "  2) 关闭屏蔽 (恢复允许云端下发)"
  echo "  3) 立即巡检一次"
  echo "  4) 查看隔离区"
  echo "  0) 返回"
  printf "选择: "; read n
  case "$n" in
    1) sh $XBT/scripts/cloud_guard.sh on ;;
    2) sh $XBT/scripts/cloud_guard.sh off ;;
    3) sh $XBT/scripts/cloud_guard.sh check ;;
    4) ls -la $XBT/state/cloud_quarantine/ 2>/dev/null ;;
  esac
  printf '\n按回车返回...'; read x
}

baa_probe_fmt() {
  _t="$BAA_TGT"
  [ -r "$_t" ] || { echo unknown; return; }
  if head -c 8 "$_t" 2>/dev/null | grep -q 'BAA_ENC:'; then echo enc; return; fi
  if head -c 64 "$_t" 2>/dev/null | grep -q '{'; then echo plain; return; fi
  echo unknown
}

baa_use_fmt() {
  _cfg=$(cfg_get baa_fmt auto)
  case "$_cfg" in enc|plain) echo "$_cfg"; return ;; esac
  if [ "$(baa_state)" != "active" ]; then
    _p=$(baa_probe_fmt)
    case "$_p" in enc|plain)
      mkdir -p "$XBT/state" 2>/dev/null
      echo "$_p" > "$XBT/state/baa_fmt" 2>/dev/null
      echo "$_p"; return ;;
    esac
  fi
  _c=$(cat "$XBT/state/baa_fmt" 2>/dev/null)
  case "$_c" in plain) echo plain ;; *) echo enc ;; esac
}

baa_refresh_src() {
  _m=normal
  _f="$XBT/baa/modes/$_m.json"
  if [ "$(cfg_get cloud_guard 1)" = "1" ] && [ -f "$XBT/baa/modes/${_m}_nocloud.json" ]; then
    _f="$XBT/baa/modes/${_m}_nocloud.json"
  fi
  if [ "$(baa_use_fmt)" = "plain" ]; then
    _c="${_f%.json}_plain.json"
    [ -f "$_c" ] && _f="$_c"
  fi
  [ -f "$_f" ] && cp -f "$_f" "$BAA_SRC"
  echo "$(basename "$_f")"
}

baa_detect_target() {
  _std=/odm/etc/charger/BAA_config_$DEV_CODE.json
  if [ -f "$_std" ]; then BAA_TGT="$_std"; return 0; fi
  for _d in /odm/etc/charger /vendor/etc/charger /my_product/etc/charger \
            /system/etc/charger /system_ext/etc/charger /product/etc/charger; do
    [ -d "$_d" ] || continue
    if [ -f "$_d/BAA_config_$DEV_CODE.json" ]; then
      BAA_TGT="$_d/BAA_config_$DEV_CODE.json"; return 0
    fi
    _any=$(ls "$_d"/BAA_config_*.json 2>/dev/null | head -n 1)
    [ -n "$_any" ] && { BAA_TGT="$_any"; return 0; }
  done
  BAA_TGT="$_std"
  return 1
}

[ -f "$BAA_TGT" ] || baa_detect_target 2>/dev/null