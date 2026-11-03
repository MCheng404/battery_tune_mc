#!/system/bin/sh
# ============================================================================

# ============================================================================

#

# ============================================================================
XBT=/data/adb/modules/battery_tune_mc
[ -f "$XBT/scripts/common.sh" ] && . "$XBT/scripts/common.sh" 2>/dev/null

B=/sys/class/power_supply/battery
PIDF="$XBT/state/apl.pid"
TGT="$XBT/state/apl_target_ma"
LOCKF="$XBT/state/apl_lock_until"
HARDF="$XBT/state/apl_hard_events"
URGF="$XBT/state/apl_urgent"
DEV=$(cfg_get dev_code unknown)
PROF="$XBT/state/apl_profile.$DEV.kv"
APL_LOG="$XBT/state/apl.csv"
WARMUP_S=90

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') apl: $*" >> /data/local/tmp/xt_toolbox.log 2>/dev/null; }
ap()  { echo "$1" > "$TGT.tmp" 2>/dev/null && mv -f "$TGT.tmp" "$TGT" 2>/dev/null; }
now() { date +%s; }

_me=$$
if command -v pgrep >/dev/null 2>&1; then
  _other=""
  for _p in $(timeout 5 pgrep -f 'battery_tune_mc/scripts/apl\.sh' 2>/dev/null); do
    [ "$_p" = "$_me" ] && continue
    kill -0 "$_p" 2>/dev/null || continue
    _other="$_p"; break
  done
  if [ -n "$_other" ] && [ "$_other" -lt "$_me" ] 2>/dev/null; then
    log "elder apl alive (pid $_other), yielding"; exit 0
  fi
fi
echo "$_me" > "$PIDF" 2>/dev/null
trap 'rm -f "$PIDF" 2>/dev/null' EXIT INT TERM

ceiling() {

  _c=20000
  _d=$(dt_curr_cap_ma 2>/dev/null); case "$_d" in ''|*[!0-9]*) _d="" ;; esac
  if [ -n "$_d" ] && [ "$_d" -gt 0 ]; then
    [ "$_d" -lt "$_c" ] && _c="$_d"
  fi

  _o=$(cfg_get apl_max_ma "")
  case "$_o" in ''|*[!0-9]*) ;; *)
    [ "$_o" -gt 0 ] && [ "$_o" -lt "$_c" ] && _c="$_o" ;; esac
  echo "$_c"
}

rd() { _x=$(cat "$1" 2>/dev/null); case "$_x" in ''|*[!0-9-]*) echo 0 ;; *) echo "$_x" ;; esac; }
vterm_mv() {
  _f=/proc/device-tree/soc/mca_strategy_quick_charge/max_vbat
  [ -e "$_f" ] || { echo 4570; return; }
  od -An -tu1 -N4 "$_f" 2>/dev/null | awk '{print $1*16777216+$2*65536+$3*256+$4}'
}

ffc_temp_high_c() {
  _f=/proc/device-tree/soc/mca_strategy_buckchg_class/ffc_temp_high
  [ -e "$_f" ] || { echo 55; return; }
  _v=$(od -An -tu1 -N4 "$_f" 2>/dev/null | awk '{print $1*16777216+$2*65536+$3*256+$4}')
  case "$_v" in ''|*[!0-9]*) echo 55 ;; *) echo "$_v" ;; esac
}
adp_fp() {
  _v=$(rd /sys/class/power_supply/usb/voltage_max)
  _p=$(rd /sys/class/xm_power/charger/charger_common/power_max 2>/dev/null)
  [ "$_p" = "0" ] && _p=$(rd /sys/class/power_supply/usb/input_power_limit)
  echo "${_v}_${_p}"
}
sam() {
  SOC=$(rd $B/capacity)
  VBAT=$(( $(rd $B/voltage_now) / 1000 ))
  IBAT=$(( $(rd $B/current_now) / 1000 )); [ "$IBAT" -lt 0 ] && IBAT=$((-IBAT))
  PBAT=$(( VBAT * IBAT / 1000 ))
  TB=$(( $(rd $B/temp) / 10 ))
  UON=$(rd /sys/class/power_supply/usb/online)
  ST=$(cat $B/status 2>/dev/null)
  VTERM=$(vterm_mv); case "$VTERM" in ''|*[!0-9]*) VTERM=4570 ;; esac
}

# ---------------- profile ----------------
prof_get() { [ -f "$PROF" ] && grep -a "^$1=" "$PROF" 2>/dev/null | head -n1 | cut -d= -f2; }
prof_set() {
  _tmp="$PROF.tmp"
  { [ -f "$PROF" ] && grep -av "^$1=" "$PROF" 2>/dev/null; echo "$1=$2"; } > "$_tmp" 2>/dev/null
  mv -f "$_tmp" "$PROF" 2>/dev/null
}

prof_best() {
  [ -f "$PROF" ] || { echo ""; return; }
  grep -a '^b[0-9]=' "$PROF" 2>/dev/null | cut -d= -f2 | awk '
    { if ($1+0 > max) max = $1+0 } END{ if (max > 0) print max }'
}

DMARK="$XBT/state/apl_dmesg_mark"
hard_fault() {
  _last=$(cat "$DMARK" 2>/dev/null); case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
  _hit=$(dmesg 2>/dev/null | tail -n 300 | grep -acE "open path fail|cp work abnormal|monitor charge abnormal")
  echo "$_hit" > "$DMARK" 2>/dev/null
  [ "$_hit" -gt "$_last" ] && return 0 || return 1
}

CAP=$(ceiling)

_FH=$(ffc_temp_high_c)
T_UP=$(( _FH - 8 ))
T_DOWN=$(( _FH - 3 ))
[ "$T_UP" -lt 40 ] && T_UP=40
[ "$T_DOWN" -lt 45 ] && T_DOWN=45
FP=$(adp_fp)
FP_OLD=$(prof_get adp)
REASON=""
[ -n "$FP_OLD" ] && [ "$FP_OLD" != "$FP" ] && REASON="适配器变更($FP_OLD→$FP)"
_seen=$(prof_get seen); case "$_seen" in ''|*[!0-9]*) _seen=0 ;; esac
if [ "$_seen" -gt 0 ] && [ $(( $(now) - _seen )) -gt 604800 ]; then
  REASON="${REASON:+$REASON; }档案>7天"
fi
if [ -n "$REASON" ]; then
  echo "_reset_$(now)=$REASON" > "$PROF.tmp" 2>/dev/null
  mv -f "$PROF.tmp" "$PROF" 2>/dev/null
  log "学习档案重置：$REASON"
fi
prof_set "adp" "$FP"
prof_set "seen" "$(now)"

_BEST=$(prof_best); case "$_BEST" in ''|*[!0-9]*) _BEST="" ;; esac
_FLOOR=$(( CAP * 75 / 100 ))
TARGET="$CAP"
[ -n "$_BEST" ] && [ "$_BEST" -gt "$_FLOOR" ] && [ "$_BEST" -le "$CAP" ] && TARGET="$_BEST"
[ "$TARGET" -lt "$_FLOOR" ] && TARGET="$_FLOOR"
[ "$TARGET" -gt "$CAP" ]    && TARGET="$CAP"
ap "$TARGET"
log "started pid=$$ dev=$DEV ceiling=${CAP}mA target=${TARGET}mA learned=${_BEST:-none} adp=$FP ffc_high=${_FH}C up=${T_UP}C down=${T_DOWN}C"

PREV_UON=0
PREV_IBAT=0; STAB_IBAT=0
LOW_CNT=0; STABLE_CNT=0
LAST_UP=$(now); WARM_START=0

while :; do
  sam
  _t=$(now)

  if [ "$UON" = "1" ] && [ "$PREV_UON" != "1" ]; then
    WARM_START=$_t
    TARGET="$CAP"; ap "$TARGET"
    prof_set "seen" "$_t"
    log "插枪边沿：热身 ${WARMUP_S}s，目标先置 ${CAP}mA（给不上会自动退让）"
    LOW_CNT=0; STABLE_CNT=0; LAST_UP=$_t
  fi
  PREV_UON="$UON"

  _let=""
  [ "$UON" != "1" ]                && _let="未插枪"
  case "$ST" in Charging|Full) ;; *) [ -z "$_let" ] && _let="status=$ST" ;; esac
  [ "$VBAT" -ge $((VTERM - 30)) ] && _let="CV段($VBAT/$VTERM)"

  if [ -n "$_let" ]; then
    ap "$CAP"

    [ -f "$APL_LOG" ] || echo "ts,soc,vbat,ibat,pbat,tb,usbV,target,locked,warm" > "$APL_LOG" 2>/dev/null
    echo "$_t,$SOC,$VBAT,$IBAT,$PBAT,$TB,$(rd /sys/class/power_supply/usb/voltage_now),$CAP,0,0" >> "$APL_LOG" 2>/dev/null
    sleep 5; continue
  fi

  prof_set "seen" "$_t"

  if hard_fault; then
    NEW=$(( IBAT * 80 / 100 ))
    _bfloor=$(( CAP * 50 / 100 ))
    [ "$NEW" -lt "$_bfloor" ] && NEW="$_bfloor"
    [ "$NEW" -gt "$CAP" ] && NEW="$CAP"
    TARGET="$NEW"; ap "$TARGET"
    echo 1 > "$URGF" 2>/dev/null
    echo "$_t hard IBAT=$IBAT -> $TARGET" >> "$HARDF" 2>/dev/null
    log "A档硬故障：目标 ${TARGET}mA，锁 30s"
    echo $(( _t + 30 )) > "$LOCKF" 2>/dev/null
    LOW_CNT=0; STABLE_CNT=0; LAST_UP=$_t
    sleep 5; continue
  fi

  _grace=0
  [ "$WARM_START" -gt 0 ] && [ $(( _t - WARM_START )) -lt 40 ] && _grace=1
  _wantp=$(( TARGET * VBAT / 1000 ))
  if [ "$_grace" = "0" ] && [ "$_wantp" -gt 0 ] && [ "$PBAT" -lt $(( _wantp * 55 / 100 )) ]; then
    LOW_CNT=$((LOW_CNT + 1))
  else
    LOW_CNT=0
  fi
  if [ "$LOW_CNT" -ge 2 ]; then
    NEW=$(( IBAT * 105 / 100 ))
    _bfloor=$(( CAP * 50 / 100 ))
    [ "$NEW" -lt "$_bfloor" ] && NEW="$_bfloor"
    [ "$NEW" -gt "$CAP" ] && NEW="$CAP"
    if [ "$NEW" -lt "$TARGET" ]; then
      TARGET="$NEW"; ap "$TARGET"

      log "B档塌陷(P=$(( PBAT / 1000 )).$(( (PBAT % 1000) / 100 ))W < 目标$(( _wantp / 1000 ))W)：降到 ${TARGET}mA，锁 60s"
      echo $(( _t + 60 )) > "$LOCKF" 2>/dev/null
      STABLE_CNT=0; LAST_UP=$_t
    fi
    LOW_CNT=0
  fi

  if [ "$TB" -ge "$T_DOWN" ]; then
    NEW=$(( TARGET * 80 / 100 ))
    _bfloor=$(( CAP * 50 / 100 ))
    [ "$NEW" -lt "$_bfloor" ] && NEW="$_bfloor"
    if [ "$NEW" -lt "$TARGET" ]; then
      TARGET="$NEW"; ap "$TARGET"
      log "电池 ${TB}℃ ≥ 降档线 ${T_DOWN}℃，降 20% → ${TARGET}mA"
      echo $(( _t + 60 )) > "$LOCKF" 2>/dev/null
      STABLE_CNT=0
    fi
  fi

  _lt=0; [ -f "$LOCKF" ] && _lt=$(cat "$LOCKF" 2>/dev/null)
  case "$_lt" in ''|*[!0-9]*) _lt=0 ;; esac
  _locked=0; [ "$_t" -lt "$_lt" ] && _locked=1

  if [ "$_wantp" -gt 0 ] && [ "$PBAT" -ge $(( _wantp * 88 / 100 )) ]; then
    STABLE_CNT=$((STABLE_CNT + 1))
  else
    STABLE_CNT=0
  fi

  if [ "$_locked" = "0" ] && [ "$TB" -lt "$T_UP" ] && [ "$TARGET" -lt "$CAP" ]; then
    _warm=0
    [ "$WARM_START" -gt 0 ] && [ $(( _t - WARM_START )) -lt "$WARMUP_S" ] && _warm=1
    _step=0; _need=99
    if [ "$_warm" = "1" ]; then
      _step=$(( TARGET * 8 / 100 )); _need=3
    elif [ "$STABLE_CNT" -ge 6 ]; then
      _step=$(( TARGET * 6 / 100 )); _need=6
    elif [ "$STABLE_CNT" -ge 9 ]; then
      _step=$(( TARGET * 3 / 100 )); _need=9
    fi
    [ "$_step" -lt 200 ] && _step=200
    if [ "$_step" -gt 0 ] && [ "$STABLE_CNT" -ge "$_need" ] && [ $(( _t - LAST_UP )) -ge 15 ]; then
      NEW=$(( TARGET + _step ))
      [ "$NEW" -gt "$CAP" ] && NEW="$CAP"
      if [ "$NEW" -gt "$TARGET" ]; then
        TARGET="$NEW"; ap "$TARGET"
        log "上探 +${_step} → ${TARGET}mA / 上限 ${CAP}mA"
        LAST_UP=$_t; STABLE_CNT=0
      fi
    fi
  fi

  _ibl=$(( IBAT * 95 / 100 ))
  _ibh=$(( IBAT * 105 / 100 ))
  if [ "$PREV_IBAT" -ge "$_ibl" ] && [ "$PREV_IBAT" -le "$_ibh" ] && [ "$IBAT" -gt 2000 ]; then
    STAB_IBAT=$((STAB_IBAT + 1))
  else
    STAB_IBAT=0
  fi

  if [ "$STAB_IBAT" -ge 3 ] && [ "$IBAT" -gt 2000 ]; then
    _b=$(( SOC / 10 )); [ "$_b" -gt 9 ] && _b=9; [ "$_b" -lt 0 ] && _b=0
    _k="b$_b"
    _real="$IBAT"
    [ "$_real" -gt "$CAP" ] && _real="$CAP"
    _old=$(prof_get "$_k"); case "$_old" in ''|*[!0-9]*) _old="" ;; esac
    if [ -n "$_old" ]; then
      if [ "$_real" -gt "$_old" ]; then
        _nv=$(( (_old * 3 + _real * 7) / 10 ))
        [ "$_nv" -gt "$CAP" ] && _nv="$CAP"
        prof_set "$_k" "$_nv"
      fi
    else
      prof_set "$_k" "$_real"
    fi
  fi

  # ---- CSV ----
  [ -f "$APL_LOG" ] || echo "ts,soc,vbat,ibat,pbat,tb,usbV,target,locked,warm" > "$APL_LOG" 2>/dev/null
  _w2=0; [ "$WARM_START" -gt 0 ] && [ $(( _t - WARM_START )) -lt "$WARMUP_S" ] && _w2=1
  echo "$_t,$SOC,$VBAT,$IBAT,$PBAT,$TB,$(rd /sys/class/power_supply/usb/voltage_now),$TARGET,$_locked,$_w2" >> "$APL_LOG" 2>/dev/null
  _lc=$(wc -l < "$APL_LOG" 2>/dev/null); case "$_lc" in ''|*[!0-9]*) _lc=0 ;; esac
  [ "$_lc" -gt 2000 ] && { tail -n 1000 "$APL_LOG" > "$APL_LOG.t" 2>/dev/null && mv -f "$APL_LOG.t" "$APL_LOG" 2>/dev/null; }

  PREV_IBAT="$IBAT"
  sleep 5
done
