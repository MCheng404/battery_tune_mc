#!/system/bin/sh

# KernelSU · Magisk · APatch
_LOG=/data/local/tmp/battery_tune_install.log
_vlog(){ echo "$(date '+%F %T') [install] $*" >> "$_LOG" 2>/dev/null; }
ip(){ ui_print "$1"; _vlog "$1"; }

_add_kv() {
  _f="$MODPATH/config/settings.conf"
  if [ -s "$_f" ] && [ "$(tail -c1 "$_f" | wc -l)" = "0" ]; then echo "" >> "$_f"; fi
  echo "$1" >> "$_f"
}

_VER=$(grep '^version=' "$MODPATH/module.prop" 2>/dev/null | head -n1 | cut -d= -f2)
[ -n "$_VER" ] || _VER="v1.0.0"
_DESC=$(grep '^description=' "$MODPATH/module.prop" 2>/dev/null | head -n1 | cut -d= -f2-)
ui_print " "
ui_print "  电池解容工具箱 $_VER"
[ -n "$_DESC" ] && ui_print "  $_DESC"
_vlog "安装开始 $_VER"

DEV=$(getprop ro.product.device)
VD=$(getprop ro.product.vendor.device)
NM=$(getprop ro.product.name)
MODEL=$(getprop ro.product.model)
SUPPORTED="haotian"
CODE=""
for _c in $SUPPORTED; do
  if [ "$DEV" = "$_c" ] || [ "$VD" = "$_c" ] || [ "$NM" = "$_c" ]; then CODE=$_c; break; fi
done
if [ -z "$CODE" ]; then
  ui_print " "
  ui_print "!! 安装已终止：设备不匹配"
  ui_print "!! 本模块仅适配 小米15 Pro (haotian)"
  ui_print "!! 当前设备：$MODEL（dev=$DEV / name=$NM）"
  abort "设备不支持"
fi
DNAME="小米15 Pro"
ip "- 设备识别：$MODEL → $CODE（$DNAME）"

POOL=$MODPATH/baa/pool/$CODE
if [ ! -d "$POOL" ]; then
  abort "安装包缺少该机型载荷目录：baa/pool/$CODE"
fi
mkdir -p $MODPATH/baa/modes
for f in normal.json normal_nocloud.json normal_plain.json normal_nocloud_plain.json; do
  cp -f "$POOL/$f" $MODPATH/baa/modes/
done
rm -f $MODPATH/baa/modes/ffc.json $MODPATH/baa/modes/ffc_nocloud.json \
      $MODPATH/baa/modes/ffc_plain.json $MODPATH/baa/modes/ffc_nocloud_plain.json
cp -f $POOL/stock_BAA_config_$CODE.json $MODPATH/baa/stock_BAA_config_$CODE.json
cp -f $POOL/payload_BAA_config_$CODE.json $MODPATH/baa/payload_BAA_config_$CODE.json
N_MODE=$(ls $MODPATH/baa/modes/*.json 2>/dev/null | wc -l)
_vlog "BAA 载荷部署：$CODE（modes ${N_MODE} 件 + payload/stock）"

if [ -d $MODPATH/baa/pool ]; then
  rm -rf $MODPATH/baa/pool 2>/dev/null
  if [ -d $MODPATH/baa/pool ]; then
    ip "- baa/pool 未完全清理（不影响功能，仅多占约 5 MB）"
  else
    _vlog "已清理安装期临时载荷 baa/pool"
  fi
fi

[ -d /data/adb/modules/battery_tune_mc/baa/pool ] && \
  rm -rf /data/adb/modules/battery_tune_mc/baa/pool 2>/dev/null

_MIG_KEYS="unlock fv_guard pss_disable pss_low_soc pss_low_hyst cycle_fake backup_dir cloud_guard baa_fmt freepps cg_min_write_gap thermal_ceil tw_enable tw_limit tw_resume tw_power_w dyn_enable dyn_mode touch_sample"

xbt_kill_all_old() {
  command -v pgrep >/dev/null 2>&1 || return 0
  for _pat in 'battery_tune_mc/scripts/charge_guard\.sh' \
              'battery_tune_mc/scripts/cycle_guard\.sh' \
              'battery_tune_mc/scripts/cloud_guard\.sh' \
              'battery_tune_mc/scripts/diag_log\.sh' \
              'battery_tune_mc/scripts/fv_guard\.sh' \
              'battery_tune_mc/scripts/fv_handler\.sh' \
              'battery_tune_mc/bin/freepps' \
              'battery_tune_mc/bin/inotifyd' ; do
    for _p in $(pgrep -f "$_pat" 2>/dev/null); do kill -9 "$_p" 2>/dev/null; done
  done

  for _p in $(pgrep -f 'fv_handler\.sh' 2>/dev/null); do kill -9 "$_p" 2>/dev/null; done

  for _pf in /data/local/tmp/xt_fv_guard.pid \
             /data/local/tmp/xt_cycle_guard.pid \
             /data/local/tmp/xt_charge_guard.pid \
             /data/local/tmp/xt_cloud_guard.pid \
             /data/local/tmp/xt_diag_log.pid; do
    [ -f "$_pf" ] || continue
    _op=$(cat "$_pf" 2>/dev/null)
    case "$_op" in
      ''|*[!0-9]*) : ;;
      *) kill -9 "$_op" 2>/dev/null ;;
    esac
  done
  return 0
}
xbt_kill_all_old
_vlog "已停止旧版守护进程"

migrate_conf() {
  _src="$1/config/settings.conf"
  [ -f "$_src" ] || return 0
  for _k in $_MIG_KEYS; do
    grep -qE "^${_k}=" "$_src" 2>/dev/null || continue
    _v=$(grep -E "^${_k}=" "$_src" 2>/dev/null | tail -n 1 | cut -d= -f2-)
    if grep -qE "^${_k}=" "$MODPATH/config/settings.conf"; then
      sed -i "s@^${_k}=.*@${_k}=${_v}@" "$MODPATH/config/settings.conf"
    else
      _add_kv "${_k}=${_v}"
    fi
  done
  _vlog "$2：已迁移用户设置"
}

PREV=/data/adb/modules/battery_tune_mc
if [ -d "$PREV" ]; then
  migrate_conf "$PREV" "升级前版本"

  if [ "$(cat "$PREV/state/pss_initial" 2>/dev/null)" = "disabled" ]; then
    mkdir -p "$MODPATH/state" 2>/dev/null
    cp -f "$PREV/state/pss_initial" "$MODPATH/state/pss_initial.polluted" 2>/dev/null
    echo "enabled" > "$MODPATH/state/pss_initial"
    _vlog "已修正 PSS 快照污染"
  fi
  if [ -d "$PREV/state" ]; then
    mkdir -p "$MODPATH/state"

    for _sf in direct_current_defaults direct_control_defaults last_real_cycle.txt baa_fmt cloud_guard.state extra_dirs.txt fv_default current_limit_node current_limit_default inf_node_capped; do
      [ -f "$PREV/state/$_sf" ] && cp -f "$PREV/state/$_sf" "$MODPATH/state/$_sf" 2>/dev/null
    done

    if [ -d "$PREV/state/cloud_quarantine" ]; then
      mkdir -p "$MODPATH/state/cloud_quarantine"
      cp -af "$PREV/state/cloud_quarantine/." "$MODPATH/state/cloud_quarantine/" 2>/dev/null
      _cq_n=$(ls -1 "$MODPATH/state/cloud_quarantine" 2>/dev/null | wc -l)
      _vlog "已迁移云控隔离区（$_cq_n 个文件）"
    fi
    _vlog "已保留升级前的运行状态"
  fi
fi

if grep -q '^dev_code=' $MODPATH/config/settings.conf; then
  sed -i "s/^dev_code=.*/dev_code=$CODE/" $MODPATH/config/settings.conf
else
  _add_kv "dev_code=$CODE"
fi
_vlog "机型代号写入：dev_code=$CODE"
if ! grep -q '^touch_sample=' "$MODPATH/config/settings.conf" 2>/dev/null; then
  _add_kv "touch_sample=1"
fi

BAA_T=/odm/etc/charger/BAA_config_$CODE.json
FMT=unknown
if [ -r "$BAA_T" ]; then
  _btsz=$(stat -c %s "$BAA_T" 2>/dev/null); case "$_btsz" in ''|*[!0-9]*) _btsz=0 ;; esac
  if [ "$_btsz" -le 8 ]; then FMT=empty
  elif head -c 8 "$BAA_T" 2>/dev/null | grep -q 'BAA_ENC:'; then FMT=enc
  elif head -c 64 "$BAA_T" 2>/dev/null | grep -q '{'; then FMT=plain; fi
fi
case "$FMT" in plain) DESCR="明文配置" ;; enc) DESCR="加密配置" ;; empty) DESCR="系统 BAA 为空（魔改包将跳过挂载）" ;; *) DESCR="未探测到（运行时再判）" ;; esac

if ! grep -q '^baa_fmt=' $MODPATH/config/settings.conf 2>/dev/null; then
  _add_kv "baa_fmt=auto"
  _vlog "BAA 载荷格式：自动探测（auto）"
else
  _bf_now=$(grep '^baa_fmt=' $MODPATH/config/settings.conf | tail -n 1 | cut -d= -f2-)
  _vlog "BAA 载荷格式：保留升级前设置（${_bf_now:-auto}）"
fi
ip "- BAA：$FMT（$DESCR，自适应挂载）"

part_size64() {
  _ps_dev="$1"
  _ps_sz=$(blockdev --getsize64 "$_ps_dev" 2>/dev/null)
  case "$_ps_sz" in
    ''|*[!0-9]*) ;;
    *) echo "$_ps_sz"; return 0 ;;
  esac
  _ps_node=$(basename "$(readlink -f "$_ps_dev" 2>/dev/null)" 2>/dev/null)
  [ -n "$_ps_node" ] || return 1
  _ps_sec=$(cat "/sys/class/block/$_ps_node/size" 2>/dev/null)
  case "$_ps_sec" in
    ''|*[!0-9]*) return 1 ;;
  esac
  echo $((_ps_sec * 512))
}

flash_local_dtbo() {
  _img=$1; _slot=$2
  _dev=/dev/block/by-name/dtbo_$_slot

  trap 'rm -f /data/local/tmp/dtbo_pad_install.img 2>/dev/null' EXIT INT TERM 2>/dev/null
  if [ ! -e "$_dev" ]; then ui_print "  !! 目标分区不存在：$_dev"; return 1; fi
  _fsz=$(stat -c %s "$_img" 2>/dev/null)
  _dsz=$(part_size64 "$_dev")

  case "$_fsz" in ''|*[!0-9]*)
    ui_print "  !! 无法读取镜像大小：$_img，已中止"; return 1 ;;
  esac
  if [ -n "$_dsz" ] && [ -n "$_fsz" ] && [ "$_fsz" -gt "$_dsz" ]; then
    ui_print "  !! 镜像大于分区，已中止"; return 1
  fi
  _bk=/sdcard/Download/dtbo_backup
  mkdir -p "$_bk" 2>/dev/null
  _bf="$_bk/dtbo_${_slot}_before_install_$(date +%Y%m%d-%H%M%S).img"
  ui_print "  -> 备份当前 dtbo_$_slot 到 $_bf"
  if ! dd if="$_dev" of="$_bf" bs=1M 2>/dev/null; then ui_print "  !! 备份失败，已中止"; return 1; fi
  sync
  ui_print "  -> 刷入 ${_HZ}Hz DTBO ..."

  _src="$_img"
  if [ -z "$_dsz" ]; then

    if [ -n "$_fsz" ]; then
      ui_print "  !! 无法读取分区大小（blockdev 不可用），为保证安全已中止刷入"
      ui_print "     备份已保留：${_bf:-（未生成）}"
      echo "$(date '+%F %T') install_flash_ABORT no_blockdev slot=$_slot" >> "$_bk/manifest.txt" 2>/dev/null
      return 1
    fi
  elif [ "$_fsz" -lt "$_dsz" ]; then
    _pad=/data/local/tmp/dtbo_pad_install.img
    if cp -f "$_img" "$_pad" 2>/dev/null && truncate -s "$_dsz" "$_pad" 2>/dev/null && \
       [ "$(stat -c %s "$_pad" 2>/dev/null)" = "$_dsz" ]; then
      _src="$_pad"
      ui_print "    镜像已补齐至分区大小"
    else
      ui_print "  !! 镜像补齐失败（truncate 不可用或空间不足），为避免写坏分区已中止"
      ui_print "     镜像 $_fsz B < 分区 $_dsz B，直写会残留旧数据"
      ui_print "     备份已保留：${_bf:-（未生成）}"
      rm -f "$_pad" 2>/dev/null
      echo "$(date '+%F %T') install_flash_ABORT pad_failed fsz=$_fsz dsz=$_dsz" >> "$_bk/manifest.txt" 2>/dev/null
      return 1
    fi
  fi
  if ! dd if="$_src" of="$_dev" bs=1M 2>/dev/null; then ui_print "  !! 写入失败"; return 1; fi
  sync
  _ssz=$(stat -c %s "$_src" 2>/dev/null)

  if [ -n "$_dsz" ]; then
    _nsha=$(head -c "$_dsz" "$_dev" 2>/dev/null | sha256sum | awk '{print $1}')
    _isha=$(sha256sum "$_src" 2>/dev/null | awk '{print $1}')
    _scope="整个分区 $_dsz B"

    if [ "$_ssz" != "$_dsz" ]; then
      ui_print "  !! 内部错误：待写镜像 $_ssz B ≠ 分区 $_dsz B，校验无法成立，已中止"
      echo "$(date '+%F %T') install_flash_ABORT size_mismatch ssz=$_ssz dsz=$_dsz" >> "$_bk/manifest.txt" 2>/dev/null
      return 1
    fi
  else
    _nsha=$(head -c "$_ssz" "$_dev" 2>/dev/null | sha256sum | awk '{print $1}')
    _isha=$(sha256sum "$_src" 2>/dev/null | awk '{print $1}')
    _scope="镜像长度 $_ssz B（分区大小未知，尾部未校验）"
  fi
  if [ -n "$_nsha" ] && [ "$_nsha" = "$_isha" ]; then
    ui_print "  ✔ DTBO 刷入成功且校验一致（$_scope；重启后生效）"
    echo "$(date '+%F %T') install_flash_OK $_slot $_nsha <- $_img scope=$_scope" >> "$_bk/manifest.txt"
    return 0
  else
    ui_print "  ✘ 校验不一致，备份已保留：$_bf"
    ui_print "    分区=$_nsha"
    ui_print "    镜像=$_isha"
    echo "$(date '+%F %T') install_flash_VERIFY_FAIL $_slot part=$_nsha file=$_isha" >> "$_bk/manifest.txt"
    return 1
  fi
}

drain_key_events() {
  { $_TO 0.25 getevent -qlc 4 >/dev/null 2>&1; } 2>/dev/null
}

key_choice() {
  _secs="${1:-0}"
  _lbl_up="${2:-刷入}"
  _lbl_dn="${3:-稍后}"
  case "$_secs" in ''|*[!0-9]*) _secs=0 ;; esac
  if ! command -v getevent >/dev/null 2>&1; then
    ui_print "  ! 环境缺少 getevent，跳过音量键选择（使用默认）"
    echo skip; return
  fi
  _TO=""
  if command -v timeout >/dev/null 2>&1; then
    _TO="timeout"
  elif [ -x /data/adb/ksu/bin/busybox ]; then
    _TO="/data/adb/ksu/bin/busybox timeout"
  elif [ -x /data/adb/magisk/busybox ]; then
    _TO="/data/adb/magisk/busybox timeout"
  elif command -v busybox >/dev/null 2>&1; then
    _TO="busybox timeout"
  elif command -v getevent >/dev/null 2>&1; then

    ui_print "  ! 环境缺少 timeout，跳过音量键选择（使用默认）"
    echo skip; return
  else
    echo skip; return
  fi
  _start=$(date +%s)
  if [ "$_secs" -gt 0 ]; then
    _end=$(( _start + _secs ))
    _hard=$(( _secs + 15 ))
  fi
  _said10=0; _said5=0
  while :; do

    _ev=$({ $_TO 1 getevent -qlc 1 2>/dev/null; } 2>/dev/null)
    case "$_ev" in
      *KEY_VOLUMEUP*)   drain_key_events; echo up;   return ;;
      *KEY_VOLUMEDOWN*) drain_key_events; echo down; return ;;
    esac

    if [ "$_secs" -gt 0 ]; then
      [ "$(date +%s)" -lt "$_end" ] || break
      [ $(( $(date +%s) - _start )) -gt "$_hard" ] && break
      _rem=$(( _end - $(date +%s) ))
      if [ "$_rem" -le 10 ] && [ "$_said10" = "0" ]; then
        echo "  （还剩约 10 秒：音量上=$_lbl_up / 音量下=$_lbl_dn）" >&2; _said10=1
      fi
      if [ "$_rem" -le 5 ] && [ "$_said5" = "0" ]; then
        echo "  （还剩约 5 秒：音量上=$_lbl_up / 音量下=$_lbl_dn）" >&2; _said5=1
      fi
    fi
  done
  echo skip
}

read_real_cycles() {
  _v=$(cat /sys/class/xm_power/fg_master/qmax_cyclecount 2>/dev/null)
  case "$_v" in ''|*[!0-9]*)
    _v=$(cat "$MODPATH/state/last_real_cycle.txt" 2>/dev/null) ;;
  esac
  case "$_v" in ''|*[!0-9]*)
    _v=$(cat /sys/class/xm_power/fg_master/cyclecount 2>/dev/null) ;;
  esac
  case "$_v" in ''|*[!0-9]*)
    _v=$(cat /sys/class/power_supply/battery/cycle_count 2>/dev/null) ;;
  esac
  case "$_v" in ''|*[!0-9]*) echo "" ;; *) echo "$_v" ;; esac
}

recommend_fake() {
  _c="$1"
  case "$_c" in ''|*[!0-9]*) echo ""; return ;; esac
  if   [ "$_c" -le 500 ]; then echo 20
  elif [ "$_c" -le 600 ]; then echo 50
  elif [ "$_c" -le 900 ]; then echo 80
  else                         echo 200
  fi
}

DR=$MODPATH/dtbo
mkdir -p $MODPATH/state

HZ_LIST="120 132 144 165"
pick_hz() {
  _pick=120
  _cur=120
  ui_print " "
  ui_print "----------------------------------------"
  ui_print "  刷新率档位选择（$DNAME）"
  for _hz in $HZ_LIST; do
    if [ "$_hz" = "$_cur" ]; then
      ui_print "    > $_hz Hz  ◀"
    else
      ui_print "      $_hz Hz"
    fi
  done
  ui_print "----------------------------------------"
  ui_print "  音量上 (+) 切换下一档 ｜ 音量下 (-) 确认"
  ui_print "  无时间限制，确认后继续"
  while :; do
    _ch=$(key_choice 0 "切换" "确认")
    case "$_ch" in
      up)
        _next=$_cur; _found=0
        for _hz in $HZ_LIST; do
          if [ "$_found" = "1" ]; then _next=$_hz; break; fi
          [ "$_hz" = "$_cur" ] && _found=1
        done
        if [ "$_next" = "$_cur" ]; then
          ui_print " "
          ui_print "  → 已是最高档 ${_cur} Hz（音量下确认 / 音量上无效）"
        else
          _cur=$_next
          ui_print " "
          ui_print "  → 当前选择 ${_cur} Hz（音量下确认 / 音量上继续）"
        fi
        ;;
      down)
        _pick=$_cur
        ui_print " "
        ui_print "  → 已确认 ${_cur} Hz"
        return
        ;;
      *) break ;;
    esac
  done
  _pick=120
  ui_print "  → 未选择，使用默认 120 Hz"
}

if [ -s "$DR/120hz.dtb" ]; then
  _hz_ok=""
  _dtb_missing=""
  for _hz in $HZ_LIST; do
    if [ -s "$DR/${_hz}hz.dtb" ]; then _hz_ok="$_hz_ok $_hz"; else _dtb_missing="$_dtb_missing $_hz"; fi
  done
  HZ_LIST=${_hz_ok# }
  [ -n "$_dtb_missing" ] && ui_print "- 帧率载荷缺失：${_dtb_missing# }（仅列出可用档位）"
  SLOT=$(getprop ro.boot.slot_suffix)
  SLOT=${SLOT#_}
  if [ -z "$SLOT" ]; then
    SLOT=$(sed -n 's/.*androidboot.slot_suffix=_\([ab]\).*/\1/p' /proc/cmdline 2>/dev/null | head -n1)
  fi
  case "$SLOT" in a|b) ;; *) SLOT=a ;; esac
  DEVC=/dev/block/by-name/dtbo_$SLOT
  BUILD_SH=$MODPATH/scripts/build_dtbo.sh
  ui_print " "
  ui_print "========================================"
  ui_print "  超频 DTBO 刷入（$DNAME）"
  ui_print "========================================"

  pick_hz
  _HZ=$_pick
  SEL_DTB="$DR/${_HZ}hz.dtb"
  ui_print " "
  ui_print "  → 档位：${_HZ} Hz"

  SEL_IMG=/data/local/tmp/dtbo_${_HZ}hz_install.img
  rm -f "$SEL_IMG"
  _dsz_sel=$(part_size64 "$DEVC")
  ui_print "  -> 构建 ${_HZ}Hz DTBO 镜像 ..."
  if ! sh "$BUILD_SH" "$SEL_DTB" "$SEL_IMG" "${_dsz_sel:-}"; then
    ui_print "  !! 镜像构建失败，已跳过刷入（可稍后在 WebUI「调整刷新率」重试）"
    echo "build-failed-${_HZ}" > $MODPATH/state/dtbo_choice
  else

    _part_hash=""
    if [ -e "$DEVC" ] && [ -n "$_dsz_sel" ]; then
      _part_hash=$(head -c "$_dsz_sel" "$DEVC" 2>/dev/null | sha256sum | awk '{print $1}')
    fi
    _want=$(sha256sum "$SEL_IMG" 2>/dev/null | awk '{print $1}')
    if [ -n "$_part_hash" ] && [ "$_part_hash" = "$_want" ]; then
      ui_print "- 当前槽 dtbo_$SLOT 已是 ${_HZ}Hz 超频版，无需重复刷入"
      echo "already-${_HZ}" > $MODPATH/state/dtbo_choice
    else
      ui_print " "
      ui_print "  当前槽 dtbo_$SLOT 尚未刷入 ${_HZ}Hz 超频版"
      ui_print "  音量上 (+) 立即刷入 ｜ 音量下 (-) 稍后（WebUI 可刷）"
      ui_print "  无时间限制，等待确认"
      ui_print "----------------------------------------"
      _ch=$(key_choice 0 "立即刷入" "稍后")
      case "$_ch" in
        up)
          ui_print "  → 已选择：立即刷入 ${_HZ}Hz"
          if flash_local_dtbo "$SEL_IMG" "$SLOT"; then
            echo "flashed-${_HZ}" > $MODPATH/state/dtbo_choice
          else
            echo "failed-${_HZ}" > $MODPATH/state/dtbo_choice
            ui_print "    可在 WebUI「调整刷新率」里重试"
          fi
          ;;
        *)
          ui_print "  → 已选择：稍后刷入（WebUI「调整刷新率」可随时刷）"
          echo "later-${_HZ}" > $MODPATH/state/dtbo_choice
          ;;
      esac
    fi

    rm -f "$SEL_IMG" 2>/dev/null
  fi
else
  ui_print "- DTBO：安装包不含可用的 120Hz 基座载荷（跳过刷入）"
fi

_rc=$(read_real_cycles)
_rec=$(recommend_fake "$_rc")

_cf_prev=""
if [ -f "$PREV/config/settings.conf" ] && grep -qE '^cycle_fake=' "$PREV/config/settings.conf" 2>/dev/null; then
  _cf_prev=$(grep -E '^cycle_fake=' "$PREV/config/settings.conf" 2>/dev/null | tail -n 1 | cut -d= -f2-)
  ui_print " "
  ui_print "- 循环伪装：沿用升级前设置（${_cf_prev:-不伪装}）"
  ui_print "  如需修改，安装后到 WebUI「循环计数」调整"
elif [ -z "$_rc" ]; then

  ui_print " "
  ui_print "- 循环伪装：未探测到循环计数节点，跳过询问（安装后可在 WebUI 设置）"
  if grep -q '^cycle_fake=' $MODPATH/config/settings.conf; then
    sed -i "s/^cycle_fake=.*/cycle_fake=/" $MODPATH/config/settings.conf
  else
    _add_kv "cycle_fake="
  fi
else
ui_print " "
ui_print "循环伪装（可选）· 真实 $_rc 次 · 推荐 ${_rec:-—} 次"
ui_print "  音量上 (+) 开启伪装 ｜ 音量下 (-) 不伪装（默认）"
_fch=$(key_choice 30 "开启伪装" "不伪装")
case "$_fch" in
  up)
    if [ -n "$_rec" ]; then

      if [ "$_rec" -gt "$_rc" ]; then _rec="$_rc"; fi
      if grep -q '^cycle_fake=' $MODPATH/config/settings.conf; then
        sed -i "s/^cycle_fake=.*/cycle_fake=$_rec/" $MODPATH/config/settings.conf
      else
        _add_kv "cycle_fake=$_rec"
      fi
      ui_print "  → 已开启：伪装为 $_rec 次（安装完成后生效）"
      ui_print "     真实值（${_rc:-未知}）由模块单独记录，WebUI 可随时改或取消"
    else
      ui_print "  → 未写入伪装值（读不到循环次数），安装后请到 WebUI 手动设置"
    fi
    ;;
  *)
    if grep -q '^cycle_fake=' $MODPATH/config/settings.conf; then
      sed -i "s/^cycle_fake=.*/cycle_fake=/" $MODPATH/config/settings.conf
    else
      _add_kv "cycle_fake="
    fi
    ui_print "  → 已选择：不伪装（保持真实循环显示）"
    ui_print "     安装后仍可在 WebUI「循环计数」里随时开启"
    ;;
esac
fi

set_perm_recursive $MODPATH 0 0 0755 0644
set_perm_recursive $MODPATH/scripts 0 0 0755 0755
set_perm $MODPATH/action.sh 0 0 0755
set_perm $MODPATH/post-fs-data.sh 0 0 0755
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755
set_perm $MODPATH/bin/freepps 0 0 0755
_vlog "文件部署完成"

ui_print " "
ui_print "========== 安装完成 =========="
ui_print " ▸ 重启后生效；入口：KernelSU 模块页 → 打开 WebUI"
ui_print " ▸ 默认开启：电池解容 / 云控屏蔽（公版 PPS 默认关，需要时开）"
ui_print " ▸ 详细说明：见模块自带 README.md"
ui_print " ▸ DTBO 是本模块唯一需要重启才生效的改动；OTA 会还原它，"
ui_print "   之后在 WebUI「调整刷新率」页重刷一次即可。"
ui_print " "
_vlog "安装完成"
