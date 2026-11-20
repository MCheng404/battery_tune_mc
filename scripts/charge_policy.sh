#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
. $XBT/scripts/common.sh

_kick() { echo 1 > "$XBT/state/policy_force" 2>/dev/null; }

_status() {
  _tw=$(cfg_get tw_enable 0)
  _dyn=$(cfg_get dyn_enable 0)
  _lim=$(tw_limit_c)
  _res=$(tw_resume_c)
  _pw=$(tw_power_w)
  _mode=$(dyn_mode)
  _act=$(cat "$XBT/state/tw_active" 2>/dev/null)
  [ "$_act" = "1" ] || _act=0
  _susp=$(cat "$XBT/state/policy_suspended" 2>/dev/null)
  [ "$_susp" = "1" ] || _susp=0
  _dcut=$(cat "$XBT/state/dyn_cut" 2>/dev/null)
  [ "$_dcut" = "1" ] || _dcut=0
  _target=$(target_current_ma "$(read_voltage_uv)")
  case "$_tw" in 1) _ts="开" ;; *) _ts="关" ;; esac
  case "$_dyn" in 1) _ds="开" ;; *) _ds="关" ;; esac
  case "$_act" in 1) _as="生效中" ;; *) _as="待命" ;; esac
  case "$_mode" in
    gentle) _mc="平缓" ;;
    aggressive) _mc="激进" ;;
    berserk) _mc="狂暴" ;;
    *) _mc="均衡" ;;
  esac
  echo "温度墙: ${_ts} | 触发 ${_lim}°C | 恢复 ${_res}°C | 目标 ${_pw}W | ${_as}"
  echo "动态充电: ${_ds} | 算法 ${_mc}"
  echo "当前目标: ${_target}mA"
  if [ "$_susp" = "1" ]; then
    echo "当前动作: 暂停充电（温度墙或动态阈值）"
  elif [ "$_dcut" = "1" ]; then
    echo "当前动作: 动态阈值已触发"
  else
    echo "当前动作: 正常充电"
  fi
}

case "$1" in
  status)
    _status
    ;;
  tw)
    case "$2" in
      on|off)
        if [ "$2" = "on" ]; then cfg_set tw_enable 1; else cfg_set tw_enable 0; fi
        _kick
        echo "温度墙已$([ "$2" = "on" ] && echo 开启 || echo 关闭)"
        ;;
      limit)
        _lv="$3"
        case "$_lv" in ''|*[!0-9]*) echo "触发温度需为 30-55 的整数"; exit 1 ;; esac
        [ "$_lv" -ge 30 ] 2>/dev/null && [ "$_lv" -le 55 ] 2>/dev/null || { echo "触发温度需为 30-55 的整数"; exit 1; }
        cfg_set tw_limit "$_lv"
        _rv=$(cfg_get tw_resume 38)
        case "$_rv" in ''|*[!0-9]*) _rv=38 ;; esac
        [ "$_rv" -ge "$_lv" ] 2>/dev/null && cfg_set tw_resume "$((_lv - 2))"
        _kick
        echo "触发温度已设为 ${_lv}°C"
        ;;
      resume)
        _v="$3"
        case "$_v" in ''|*[!0-9]*) echo "恢复温度需为 25-54 的整数"; exit 1 ;; esac
        _l=$(tw_limit_c)
        [ "$_v" -ge 25 ] 2>/dev/null && [ "$_v" -lt "$_l" ] 2>/dev/null || { echo "恢复温度需低于触发温度（${_l}°C）"; exit 1; }
        cfg_set tw_resume "$_v"
        _kick
        echo "恢复温度已设为 ${_v}°C"
        ;;
      power)
        _v="$3"
        case "$_v" in ''|*[!0-9]*) echo "限制功率需为 5-60 的整数"; exit 1 ;; esac
        [ "$_v" -ge 5 ] 2>/dev/null && [ "$_v" -le 60 ] 2>/dev/null || { echo "限制功率需为 5-60W"; exit 1; }
        cfg_set tw_power_w "$_v"
        _kick
        echo "目标功率已设为 ${_v}W"
        ;;
      *)
        echo "用法: charge_policy.sh tw on|off|limit N|resume N|power N"
        exit 1
        ;;
    esac
    ;;
  dyn)
    case "$2" in
      on|off)
        if [ "$2" = "on" ]; then cfg_set dyn_enable 1; else cfg_set dyn_enable 0; fi
        _kick
        echo "动态充电已$([ "$2" = "on" ] && echo 开启 || echo 关闭)"
        ;;
      mode)
        case "$3" in
          gentle|balanced|aggressive|berserk)
            cfg_set dyn_mode "$3"
            _kick
            echo "动态算法已切换为 $3"
            ;;
          *)
            echo "算法需为 gentle|balanced|aggressive|berserk"
            exit 1
            ;;
        esac
        ;;
      *)
        echo "用法: charge_policy.sh dyn on|off|mode NAME"
        exit 1
        ;;
    esac
    ;;
  *)
    echo "用法: charge_policy.sh status|tw|dyn"
    exit 1
    ;;
esac
