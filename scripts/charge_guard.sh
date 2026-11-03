#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
. $XBT/scripts/common.sh

BAT=/sys/class/power_supply/battery
ONCE="$1"
LAST_ST=""
LAST_KEY=""
LAST_MISSING=""
LAST_VOLT=""
TICKS=0

# ============================================================================

# ============================================================================

#

#

# ============================================================================
CG_GAP_DEFAULT=60

CG_LAST_TS="$XBT/state/cg_last_write_ts"

cg_gap_ok() {

  if [ -f "$XBT/state/apl_urgent" ]; then
    rm -f "$XBT/state/apl_urgent" 2>/dev/null
    log "charge_guard: APL 紧急通道放行（绕过 cg_min_write_gap）"
    return 0
  fi
  _gap=$(cfg_get cg_min_write_gap "$CG_GAP_DEFAULT")
  case "$_gap" in ''|*[!0-9]*) _gap=$CG_GAP_DEFAULT ;; esac
  [ "$_gap" -gt 0 ] 2>/dev/null || _gap=$CG_GAP_DEFAULT
  _lw=$(cat "$CG_LAST_TS" 2>/dev/null)
  case "$_lw" in ''|*[!0-9]*) _lw=0 ;; esac
  [ "$_lw" = "0" ] && return 0

  _now=$(date +%s)
  if [ "$_lw" -gt "$_now" ] 2>/dev/null; then
    rm -f "$CG_LAST_TS" 2>/dev/null
    return 0
  fi

  _diff=$((_now - _lw))
  case "$_diff" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_diff" -ge "$_gap" ] && return 0
  return 1
}

cg_note_write() {
  date +%s > "$CG_LAST_TS" 2>/dev/null
}

cg_gap_left() {
  _gap=$(cfg_get cg_min_write_gap "$CG_GAP_DEFAULT")
  case "$_gap" in ''|*[!0-9]*) _gap=$CG_GAP_DEFAULT ;; esac
  _lw=$(cat "$CG_LAST_TS" 2>/dev/null)
  case "$_lw" in ''|*[!0-9]*) _lw=0 ;; esac
  [ "$_lw" = "0" ] && { echo 0; return; }
  _now=$(date +%s)

  [ "$_lw" -gt "$_now" ] 2>/dev/null && { echo 0; return; }
  _diff=$((_now - _lw))
  case "$_diff" in ''|*[!0-9]*) echo 0; return ;; esac
  _d=$((_gap - _diff))
  [ "$_d" -lt 0 ] && _d=0
  echo "$_d"
}

chg_state_cn() {
  case "$(cat "$BAT/status" 2>/dev/null)" in
    Full) echo "已充满" ;;
    *Charging*) echo "充电中" ;;
    Discharging) echo "放电中" ;;
    *) echo "未充电" ;;
  esac
}

apply_once() {

  _sra="$XBT/state/thermal_restore_active"
  if [ -f "$_sra" ]; then
    rm -f "$_sra" 2>/dev/null
    log "charge_guard: removed stale thermal_restore_active (dead switch)"
  fi

  _cur_nodes=$(direct_current_nodes)
  if [ -z "$_cur_nodes" ]; then
    [ "$LAST_MISSING" = "1" ] || log "charge_guard: no writable current node"
    LAST_MISSING=1
    echo 0 > "$XBT/state/direct_control_active" 2>/dev/null
    return 1
  fi
  LAST_MISSING=0
  snapshot_current_limit
  snapshot_control_limit

  _mode=$(power_now)
  TICKS=$((TICKS + 1))

  if [ "$(cat "$XBT/state/power_mode_applied" 2>/dev/null)" = "$_mode" ] &&
    direct_tier_is_applied "$_mode"; then
    echo 1 > "$XBT/state/direct_control_active" 2>/dev/null
    return 0
  fi

  if [ "$(cat "$XBT/state/power_mode_applied" 2>/dev/null)" = "$_mode" ]; then
    _rs=$(cat "$XBT/state/rewrite_streak" 2>/dev/null)
    case "$_rs" in ''|*[!0-9]*) _rs=0 ;; esac
    _rs=$((_rs + 1))
    echo "$_rs" > "$XBT/state/rewrite_streak" 2>/dev/null
    case "$_rs" in
      5|20|60)

        log "charge_guard: WARN 连续重写 ${_rs} 次未稳定，可能有其它进程在改写节点(ctrl/thermal/curr)"
        ;;
    esac
  else
    echo 0 > "$XBT/state/rewrite_streak" 2>/dev/null
  fi

  if [ "$_mode" = "inf" ]; then

    _th1=$([ "$(thermal_target)" = "1" ] && echo 1 || echo 0)

      _need=0
      for _p in $(direct_thermal_remove_nodes); do
        [ -e "$_p" ] || continue
        [ "$(cat "$_p" 2>/dev/null)" = "$_th1" ] || _need=1
      done
      for _p in $(direct_limit_nodes); do
        [ -e "$_p" ] || continue
        [ "$(cat "$_p" 2>/dev/null)" = "0" ] || _need=1
      done
      if [ "$_need" = "1" ]; then
        for _p in $(direct_thermal_remove_nodes); do
          [ -e "$_p" ] || continue
          chmod 664 "$_p" 2>/dev/null
          echo "$_th1" > "$_p" 2>/dev/null
        done
        for _p in $(direct_limit_nodes); do
          [ -e "$_p" ] || continue
          chmod 664 "$_p" 2>/dev/null
          echo 0 > "$_p" 2>/dev/null
        done
      fi

      #

      #

      _settled="$XBT/state/inf_settled"
      _settle_ts="$XBT/state/inf_settle_ts"

      if [ "$_th1" = "1" ] && [ ! -f "$_settled" ] && [ ! -f "$XBT/state/inf_node_capped" ]; then
        _cur_ma=$(direct_node_read_ma_all 2>/dev/null)
        case "$_cur_ma" in ''|*[!0-9]*) _cur_ma=0 ;; esac

        case "$(cat "$BAT/status" 2>/dev/null)" in
          *Charging*|Full)
            if [ "$_cur_ma" -ge 10000 ]; then

              date +%s > "$_settle_ts" 2>/dev/null
            else

              _last=$(cat "$_settle_ts" 2>/dev/null)
              case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
              _now=$(date +%s)
              if cg_gap_ok; then
                if [ $((_now - _last)) -ge 60 ]; then
                  _fm=$(tier_target_ma inf)
                  case "$_fm" in ''|*[!0-9]*) _fm=20000 ;; esac
                  direct_set_current_ma "$_fm" "$_th1" >/dev/null 2>&1
                  cg_note_write
                  echo "$_now" > "$_settle_ts" 2>/dev/null
                  _after=$(direct_node_read_ma_all 2>/dev/null)
                  case "$_after" in ''|*[!0-9]*) _after=0 ;; esac
                  _fc="$XBT/state/inf_settle_fail"
                  _fn=$(cat "$_fc" 2>/dev/null)
                  case "$_fn" in ''|*[!0-9]*) _fn=0 ;; esac

                  if [ "$_after" -ge 10000 ]; then
                    rm -f "$_fc" 2>/dev/null
                    rm -f "$XBT/state/inf_override_cnt" 2>/dev/null
                    echo "$_now" > "$_settled" 2>/dev/null
                    log "charge_guard: inf 安顿成功 (节点 $_cur_ma -> $_after mA，进入稳态后不再写)"
                  else
                    _fn=$((_fn + 1))
                    echo "$_fn" > "$_fc" 2>/dev/null
                    if [ "$_fn" -ge 3 ]; then

                      #

                      echo "$_now" > "$_settled" 2>/dev/null
                      echo "$_after" > "$XBT/state/inf_node_capped" 2>/dev/null
                      log "charge_guard: inf 该机型电流节点上限 ${_after}mA(<10A)，已安顿(不再重试)"
                    else
                      log "charge_guard: inf 安顿未生效 (节点 $_cur_ma -> $_after mA)，60 秒后重试($_fn/3)"
                    fi
                  fi
                fi
              fi
            fi
            ;;
        esac
      fi

      if [ -f "$XBT/state/inf_settled" ]; then
        _sc_ts="$XBT/state/inf_selfcheck_ts"
        _sc_last=$(cat "$_sc_ts" 2>/dev/null)
        case "$_sc_last" in ''|*[!0-9]*) _sc_last=0 ;; esac
        _sc_now=$(date +%s)
        if [ $((_sc_now - _sc_last)) -ge 300 ]; then
          echo "$_sc_now" > "$_sc_ts" 2>/dev/null

          if [ ! -f "$XBT/state/inf_node_capped" ]; then
            case "$(cat "$BAT/status" 2>/dev/null)" in
              *Charging*)
                if [ "$(cat "$XBT/state/direct_control_active" 2>/dev/null)" = "1" ]; then
                  _sc_ma=$(direct_node_read_ma_all 2>/dev/null)
                  case "$_sc_ma" in ''|*[!0-9]*) _sc_ma=0 ;; esac
                  if [ "$_sc_ma" -lt 10000 ]; then

                    _oc="$XBT/state/inf_override_cnt"
                    _ocn=$(cat "$_oc" 2>/dev/null)
                    case "$_ocn" in ''|*[!0-9]*) _ocn=0 ;; esac
                    _ocn=$((_ocn + 1))
                    echo "$_ocn" > "$_oc" 2>/dev/null
                    if [ "$_ocn" -ge 2 ]; then
                      echo "$_sc_ma" > "$XBT/state/inf_node_capped" 2>/dev/null
                      log "charge_guard: inf 节点被系统反复接管(${_ocn}次，当前${_sc_ma}mA) —— 判定本机型该节点不可控，本次开机停止后续写入（实测不影响实际充电电流）"
                    else
                      rm -f "$XBT/state/inf_settled" 2>/dev/null
                      log "charge_guard: inf 自纠正 —— 已落旗但节点仅 ${_sc_ma}mA，清旗重试补写($_ocn/2)"
                    fi
                  fi
                fi
                ;;
            esac
          fi
        fi
      fi

      if [ ! -f "$XBT/state/inf_settled" ]; then
        if ! cg_gap_ok; then
          _gl_ts="$XBT/state/cg_gap_log_ts"
          _gl_last=$(cat "$_gl_ts" 2>/dev/null)
          case "$_gl_last" in ''|*[!0-9]*) _gl_last=0 ;; esac
          _gl_now=$(date +%s)
          if [ $((_gl_now - _gl_last)) -ge 300 ]; then
            echo "$_gl_now" > "$_gl_ts" 2>/dev/null
            _gl_gap=$(cfg_get cg_min_write_gap "$CG_GAP_DEFAULT")
            case "$_gl_gap" in ''|*[!0-9]*) _gl_gap=$CG_GAP_DEFAULT ;; esac
            _gl_left=$(cg_gap_left)
            log "charge_guard: inf 补写被全局限流挡住（间隔 ${_gl_gap}s，还需 ${_gl_left}s）—— 静默等待，不做 PD 重协商"
          fi
        fi
      fi

      echo 1 > "$XBT/state/direct_control_active" 2>/dev/null
      echo "inf" > "$XBT/state/power_mode_applied" 2>/dev/null

      echo 0 > "$XBT/state/rewrite_streak" 2>/dev/null
      LAST_KEY="inf"
      return 0
    fi

  echo 0 > "$XBT/state/direct_control_active" 2>/dev/null
  log "charge_guard: tier write failed mode=$_mode"
  return 1
}

show_status() {
  _mode=$(power_now)
  _v=$(read_voltage_uv)
  _i=$(cat "$BAT/current_now" 2>/dev/null)
  _st=$(cat "$BAT/status" 2>/dev/null)
  _tmp=$(cat "$BAT/temp" 2>/dev/null)
  _soc=$(cat "$BAT/capacity" 2>/dev/null)

  if [ -n "$_v" ] && [ -n "$_i" ]; then
    awk -v v="$_v" -v i="$_i" -v st="$(chg_state_cn)" 'BEGIN{ if(i<0)i=-i; printf "实测功率 : %.1f W (%s)\n", v*i/1e12, st}'
  fi
  if [ -n "$(direct_limit_nodes)" ]; then
    echo "内核旋钮 : thermal_remove=$(cat "$DIRECT_WIRED_THERMAL_REMOVE" 2>/dev/null) · ctrl_limit=$(cat "$DIRECT_WIRED_CTRL" 2>/dev/null)"
  else
    echo "内核旋钮 : 未发现可写节点（需本机型内核支持）"
  fi
  printf "电池状态 : %s" "${_st:-未知}"
  [ -n "$_soc" ] && printf " · %s%%" "$_soc"
  if [ -n "$_tmp" ]; then
    awk -v t="$_tmp" 'BEGIN{printf " · %.1f°C", t/10}'
  fi
  echo
}

log "charge_guard: started (pid $$, once=$ONCE, v2.1.1, $(grep '^version=' $XBT/module.prop 2>/dev/null | cut -d= -f2), dev=$(cfg_get dev_code ''))"
case "$ONCE" in
  status)
    show_status
    exit 0
    ;;
  once)
    apply_once
    exit $?
    ;;
  stop)

    _n=0
    if command -v pgrep >/dev/null 2>&1; then
      for _p in $(timeout 5 pgrep -f 'battery_tune_mc/scripts/charge_guard\.sh' 2>/dev/null); do
        [ "$_p" = "$$" ] && continue
        _cl=$(timeout 1 cat "/proc/$_p/cmdline" 2>/dev/null | tr '\0' ' ')
        case "$_cl" in
          *charge_guard.sh\ status*|*charge_guard.sh\ once*|*charge_guard.sh\ stop*) continue ;;
        esac
        kill -TERM "$_p" 2>/dev/null && _n=$((_n + 1))
      done
      sleep 0.6

      for _p in $(timeout 5 pgrep -f 'battery_tune_mc/scripts/charge_guard\.sh' 2>/dev/null); do
        [ "$_p" = "$$" ] && continue
        _cl=$(timeout 1 cat "/proc/$_p/cmdline" 2>/dev/null | tr '\0' ' ')
        case "$_cl" in
          *charge_guard.sh\ status*|*charge_guard.sh\ once*|*charge_guard.sh\ stop*) continue ;;
        esac
        kill -9 "$_p" 2>/dev/null
      done
    fi

    rm -f "$XBT/state/inf_settled" "$XBT/state/inf_settle_ts" "$XBT/state/inf_selfcheck_ts" 2>/dev/null
    log "charge_guard: stop -> killed $_n instance(s)"
    echo "charge_guard: 已停止 $_n 个长驻实例"
    exit 0
    ;;
esac

#

if command -v pgrep >/dev/null 2>&1; then
  _me=$$
  _other=""
  for _w in 1 2 3; do
    _other=""
    for _p in $(timeout 5 pgrep -f 'battery_tune_mc/scripts/charge_guard\.sh' 2>/dev/null); do
      [ "$_p" = "$_me" ] && continue
      kill -0 "$_p" 2>/dev/null || continue
      _cl=$(timeout 1 cat "/proc/$_p/cmdline" 2>/dev/null | tr '\0' ' ')

      case "$_cl" in
        *charge_guard.sh\ status*|*charge_guard.sh\ once*) ;;
        *charge_guard.sh*) _other="$_p" ;;
      esac
      [ -n "$_other" ] && break
    done
    [ -z "$_other" ] && break
    sleep 0.5
  done

  if [ -n "$_other" ] && [ "$_other" -lt "$_me" ] 2>/dev/null; then
    log "charge_guard: elder instance alive (pid $_other < $_me), yield self=$_me"
    exit 0
  elif [ -n "$_other" ]; then
    log "charge_guard: self=$_me takes over (younger $ _other=$_other will yield)"
  fi
fi

rm -f "$XBT/state/inf_settled" "$XBT/state/inf_settle_ts" "$XBT/state/inf_selfcheck_ts" "$XBT/state/inf_settle_fail" 2>/dev/null

mkdir -p "$XBT/state" 2>/dev/null
echo $$ > "$XBT/state/cg.pid" 2>/dev/null
date +%s > "$XBT/state/cg_started_ts" 2>/dev/null

while true; do
  apply_once

  case $((TICKS % 15)) in 1) pss_guard_tick ;; esac

  case $((TICKS % 300)) in 1) xbt_clean_stuck_tr ;; esac
  _st=$(cat "$BAT/status" 2>/dev/null)

  _now_t=$(date +%s)
  case "$_now_t" in ''|*[!0-9]*) _now_t=0 ;; esac
  if [ "$_st" = "Discharging" ]; then
    [ -z "$DISC_SINCE" ] && DISC_SINCE=$_now_t
    DISC_DUR=0
  elif [ -n "$DISC_SINCE" ]; then
    DISC_DUR=$((_now_t - DISC_SINCE))
  else
    DISC_DUR=-1
  fi
  if [ -n "$_st" ] && [ "$_st" != "Discharging" ] && [ "$_st" != "$LAST_ST" ]; then

    DISC_MIN=$(cfg_get cg_disc_min_sec 5)
    case "$DISC_MIN" in ''|*[!0-9]*) DISC_MIN=5 ;; esac
    _evt_real=1
    case "$LAST_ST" in
      '') _evt_real=1 ;;
      Discharging)

        if [ "$DISC_DUR" -ge "$DISC_MIN" ] 2>/dev/null || [ "$DISC_DUR" -lt 0 ] 2>/dev/null; then
          _evt_real=1
        else
          _evt_real=0
          log "charge_guard: 忽略短促状态抖动 (Discharging 仅 ${DISC_DUR}s < ${DISC_MIN}s) —— 判为 OVP/JEITA 抖动，不清安顿旗"
        fi
        ;;
      *)

        _evt_real=0
        ;;
    esac
    if [ "$_evt_real" = "1" ]; then
      log "charge_guard: charger event ($LAST_ST -> $_st), target=inf"

      rm -f "$XBT/state/inf_settled" "$XBT/state/inf_settle_ts" "$XBT/state/inf_selfcheck_ts" "$XBT/state/inf_settle_fail" 2>/dev/null
    fi
  fi

  [ "$_st" != "Discharging" ] && DISC_SINCE=""
  LAST_ST="$_st"
  sleep 1
done
