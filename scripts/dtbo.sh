#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
. $XBT/scripts/common.sh

BK=$(cfg_get backup_dir "/sdcard/Download/dtbo_backup")
MANIFEST=$BK/manifest.txt
BLK=/dev/block/by-name
EDIRS_FILE=$XBT/state/extra_dirs.txt

mkdir -p "$BK" 2>/dev/null
mkdir -p "$XBT/state" 2>/dev/null

slot_dev() { echo "$BLK/dtbo_$1"; }

blk_sha() { dd if="$1" bs=1M 2>/dev/null | sha256sum | awk '{print $1}'; }

blk_md5() { dd if="$1" bs=1M 2>/dev/null | md5sum | awk '{print $1}'; }

show_status() {
  echo "[两槽状态]"
  echo "当前卡槽: _$(slot_letter)"
  echo "备份目录: $BK"
  slot=$(slot_letter)
  for s in a b; do
    _d=$(slot_dev $s)
    [ -e "$_d" ] || continue
    _sha=$(blk_sha "$_d")
    _md5=$(blk_md5 "$_d")
    _short=$(echo "$_sha" | cut -c1-12)
    _cur=""
    [ "$s" = "$slot" ] && _cur=" (运行槽)"
    echo "  dtbo_$s : $_short...${_cur}"
    echo "  md5: $_md5"
  done
}

scan_one_dir() {
  [ -d "$1" ] || return 0
  for _f in "$1"/*.img; do
    [ -f "$_f" ] || continue
    _i=$((_i+1))
    _sz=$(stat -c %s "$_f" 2>/dev/null)
    _sh=$(hash_of "$_f")
    echo "$_i|$_f|$_sz|$(echo $_sh | cut -c1-12)|"
  done
}

list_candidates() {
  _i=0
  _n=0
  if [ -s "$EDIRS_FILE" ]; then
    while IFS= read -r _ed; do
      [ -n "$_ed" ] || continue
      _n=$((_n+1))
      scan_one_dir "$_ed"
    done < "$EDIRS_FILE"
  fi
  if [ "$_i" = "0" ]; then
    if [ "$_n" = "0" ]; then
      echo "(未添加扫描目录——请先在“自定义目录”里添加至少一个文件夹)"
    else
      echo "(已扫描 $_n 个目录，未找到 .img 文件)"
    fi
  fi
  return 0
}

show_dirs() {
  echo "[扫描目录]（列表 = 你添加的目录）"
  echo
  if [ -s "$EDIRS_FILE" ]; then
    _n=0
    while IFS= read -r _d; do
      [ -n "$_d" ] || continue
      _n=$((_n+1))
      if [ -d "$_d" ]; then echo "  ✓ $_d"; else echo "  - $_d (目录不存在)"; fi
    done < "$EDIRS_FILE"
    [ "$_n" = "0" ] && echo "  (无)"
  else
    echo "  (无——尚未添加任何目录)"
  fi
  echo
  echo "添加: dtbo.sh adddir <目录>  |  移除: dtbo.sh deldir <目录>"
}

list_extra_dirs() {
  [ -s "$EDIRS_FILE" ] && cat "$EDIRS_FILE"
  return 0
}

norm_dir() { echo "$1" | sed 's:/*$::'; }

add_scan_dir() {
  _p=$(norm_dir "$1")
  [ -n "$_p" ] || { echo "用法: dtbo.sh adddir <目录路径>"; return 1; }
  case "$_p" in
    /*) ;;
    *) echo "请使用绝对路径（以 / 开头）"; return 1 ;;
  esac
  [ -d "$_p" ] || { echo "目录不存在: $_p （请先在文件管理器创建该文件夹）"; return 1; }
  mkdir -p "$XBT/state"
  touch "$EDIRS_FILE"
  if grep -Fxq "$_p" "$EDIRS_FILE" 2>/dev/null; then
    echo "已在扫描列表中: $_p"; return 0
  fi
  echo "$_p" >> "$EDIRS_FILE"
  log "dtbo: adddir $_p"
  echo "已添加: $_p"
  echo "现在刷新镜像列表即可看到该目录中的 .img 文件"
}

del_scan_dir() {
  _p=$(norm_dir "$1")
  [ -n "$_p" ] || { echo "用法: dtbo.sh deldir <目录路径>"; return 1; }
  [ -s "$EDIRS_FILE" ] || { echo "扫描列表为空"; return 0; }
  if ! grep -Fxq "$_p" "$EDIRS_FILE" 2>/dev/null; then
    echo "不在扫描列表中: $_p"; return 1
  fi
  grep -Fxv "$_p" "$EDIRS_FILE" > "$EDIRS_FILE.tmp" 2>/dev/null
  mv -f "$EDIRS_FILE.tmp" "$EDIRS_FILE"
  log "dtbo: deldir $_p"
  echo "已移除: $_p"
}

show_info() {
  f="$1"
  [ -f "$f" ] || { echo "文件不存在: $f"; return 1; }
  echo "文件   : $f"
  echo "大小   : $(stat -c %s "$f") bytes"
  _mt=$(stat -c %Y "$f" 2>/dev/null)
  [ -n "$_mt" ] && echo "修改时间: $(date -d @$_mt '+%F %T' 2>/dev/null || echo $_mt)"
  echo "sha256 : $(hash_of "$f")"
  _mg=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')
  echo "magic  : $_mg $( [ "$_mg" = "d7b7ab1e" ] && echo '(标准dtbo)' || echo '(注意:非标准头)' )"
}

do_backup() {
  s="${1:-$(slot_letter)}"
  case "$s" in a|b) ;; *) echo "槽参数必须是 a 或 b"; return 1 ;; esac
  dev=$(slot_dev "$s")
  [ -e "$dev" ] || { echo "分区不存在: $dev"; return 1; }
  mkdir -p "$BK"
  _sha=$(blk_sha "$dev")
  _f="$BK/dtbo_${s}_manual_$(date +%Y%m%d-%H%M%S).img"
  echo "备份 dtbo_$s ..."
  if dd if="$dev" of="$_f" bs=1M 2>/dev/null; then
    sync
    echo "$(date '+%F %T') manual_backup $s $_sha $(basename "$_f")" >> "$MANIFEST"
    echo "备份完成: $_f"
    echo "sha256: $_sha"
  else
    echo "备份失败"; rm -f "$_f"
    return 1
  fi
}

do_flash() {
  f="$1"
  s="${2:-$(slot_letter)}"
  case "$s" in a|b) ;; *) echo "槽参数必须是 a 或 b"; return 1 ;; esac
  [ -f "$f" ] || { echo "文件不存在: $f"; return 1; }
  dev=$(slot_dev "$s")
  [ -e "$dev" ] || { echo "分区不存在: $dev"; return 1; }

  fsz=$(stat -c %s "$f" 2>/dev/null)
  dsz=$(blockdev --getsize64 "$dev" 2>/dev/null)
  echo "目标分区: $dev ($dsz bytes)"
  echo "镜像文件: $f ($fsz bytes)"
  if [ -n "$dsz" ] && [ "$fsz" -gt "$dsz" ]; then
    echo "错误: 镜像大于分区，中止"
    return 1
  fi
  if [ -n "$dsz" ] && [ "$fsz" -lt "$dsz" ]; then
    echo "提示: 镜像小于分区，将按文件大小写入（未补全镜像可能残留旧尾部数据）"
  fi

  _bsha=$(blk_sha "$dev")
  _dup=""
  [ -f "$MANIFEST" ] && _dup=$(grep -F "$_bsha" "$MANIFEST" | head -n 1)
  if [ -z "$_dup" ]; then
    mkdir -p "$BK"
    _bf="$BK/dtbo_${s}_before_$(date +%Y%m%d-%H%M%S).img"
    echo "-> 自动备份当前槽到: $_bf"
    if dd if="$dev" of="$_bf" bs=1M 2>/dev/null; then
      sync
      echo "$(date '+%F %T') auto_before_flash $s $_bsha $(basename "$_bf")" >> "$MANIFEST"
      echo "   备份sha256: $_bsha"
    else
      echo "   ! 备份失败，为安全中止刷写"
      return 1
    fi
  else
    echo "-> 当前槽内容已有备份记录，跳过: $_bsha"
  fi

  echo "-> 刷入中..."

  _src="$f"
  _used_pad=0
  if [ -n "$dsz" ] && [ -n "$fsz" ] && [ "$fsz" -lt "$dsz" ]; then
    _pad=/data/local/tmp/dtbo_pad.img
    if cp -f "$f" "$_pad" 2>/dev/null && truncate -s "$dsz" "$_pad" 2>/dev/null && \
       [ "$(stat -c %s "$_pad" 2>/dev/null)" = "$dsz" ]; then
      _src="$_pad"
      _used_pad=1
      echo "   镜像已补齐至分区大小 ($dsz bytes)"
    else

      echo "   ! 补齐失败（cp/truncate 异常或尺寸复核不符）→ 为安全【中止刷写】，分区未被改动"
      rm -f "$_pad" 2>/dev/null
      return 1
    fi
  fi
  if dd if="$_src" of="$dev" bs=1M 2>/dev/null; then
    sync
    echo "-> 校验..."

    _ssz=$(stat -c %s "$_src" 2>/dev/null)
    case "$_ssz" in ''|*[!0-9]*) _ssz=$(stat -c %s "$f" 2>/dev/null) ;; esac
    case "$_ssz" in ''|*[!0-9]*)
      echo "   ! 无法读取镜像大小，跳过校验（写入已完成，请重启后看 diag 结论）"
      _ssz=""
      ;;
    esac
    if [ -n "$_ssz" ]; then
      _nsha=$(head -c "$_ssz" "$dev" 2>/dev/null | sha256sum | awk '{print $1}')

      _fsha=$(hash_of "$_src")
      if [ -n "$_nsha" ] && [ "$_nsha" = "$_fsha" ]; then
        echo "=================================="
        echo "刷入成功且校验一致 (重启后生效)"
        echo "sha256: $_nsha"
        echo "=================================="
        echo "$(date '+%F %T') flash_OK $s $_nsha <- $f" >> "$MANIFEST"
        [ "$_used_pad" = "1" ] && rm -f "$_pad" 2>/dev/null
      else
        echo "校验不一致! 分区=$_nsha 文件=$_fsha"
        echo "请用备份恢复或重刷"
        echo "$(date '+%F %T') flash_VERIFY_FAIL $s part=$_nsha file=$_fsha" >> "$MANIFEST"
        [ "$_used_pad" = "1" ] && rm -f "$_pad" 2>/dev/null
        return 1
      fi
    fi

    [ "$_used_pad" = "1" ] && rm -f "$_pad" 2>/dev/null
  else
    echo "dd 写入失败!"
    [ "$_used_pad" = "1" ] && rm -f "$_pad" 2>/dev/null
    return 1
  fi
}

autobackup() {
  mkdir -p "$BK" 2>/dev/null
  s=$(slot_letter)
  dev=$(slot_dev "$s")
  [ -e "$dev" ] || exit 0
  _sha=$(blk_sha "$dev")
  if [ -f "$MANIFEST" ] && grep -qF "$_sha" "$MANIFEST" 2>/dev/null; then
    exit 0
  fi
  _f="$BK/dtbo_${s}_auto_$(date +%Y%m%d-%H%M%S).img"
  if dd if="$dev" of="$_f" bs=1M 2>/dev/null; then
    sync
    echo "$(date '+%F %T') auto_backup $s $_sha $(basename "$_f")" >> "$MANIFEST"
    log "dtbo: autobackup saved $_f"
  fi
  exit 0
}

build_and_flash() {
  hz="$1"; s="${2:-$(slot_letter)}"
  case "$hz" in 120|132|144|156|165) ;; *)
    echo "帧率参数必须是 120/132/144/156/165"; return 1 ;; esac
  dtb="$XBT/dtbo/${hz}hz.dtb"
  [ -f "$dtb" ] || { echo "载荷缺失: $dtb"; return 1; }
  dev=$(slot_dev "$s")
  [ -e "$dev" ] || { echo "分区不存在: $dev"; return 1; }
  img=/data/local/tmp/dtbo_${hz}hz_webui.img
  rm -f "$img" 2>/dev/null
  dsz=$(blockdev --getsize64 "$dev" 2>/dev/null)
  echo "-> 构建 ${hz}Hz DTBO 镜像 ..."
  if ! sh "$XBT/scripts/build_dtbo.sh" "$dtb" "$img" "${dsz:-}"; then
    echo "build-failed-${hz}" > "$XBT/state/dtbo_choice" 2>/dev/null
    echo "构建失败，已中止（分区未改动）"; return 1
  fi
  echo "-> 刷入 dtbo_$s ..."
  do_flash "$img" "$s"
  rc=$?
  if [ "$rc" = "0" ]; then echo "flashed-${hz}" > "$XBT/state/dtbo_choice" 2>/dev/null; else echo "failed-${hz}" > "$XBT/state/dtbo_choice" 2>/dev/null; fi
  rm -f "$img" 2>/dev/null
  return $rc
}

case "$1" in
  status) show_status ;;
  list) list_candidates ;;
  info) show_info "$2" ;;
  backup) do_backup "$2" ;;
  flash) do_flash "$2" "$3" ;;
  build) build_and_flash "$2" "$3" ;;
  flashlocal)
    _choice=$(cat "$XBT/state/dtbo_choice" 2>/dev/null)
    _hz=$(echo "$_choice" | sed -n 's/^[a-z]*-\([0-9]*\)$/\1/p')
    case "$_hz" in 120|132|144|156|165) ;;
      *) echo "没有已选帧率记录，请用: dtbo.sh build <hz> [slot]"; exit 1 ;;
    esac
    build_and_flash "$_hz" "${2:-$(slot_letter)}"
    ;;
  haslocal) if [ -s "$XBT/state/dtbo_choice" ]; then echo "yes"; else echo "no"; fi ;;
  autobackup) autobackup ;;
  dirs) show_dirs ;;
  dirslist) list_extra_dirs ;;
  adddir) add_scan_dir "$2" ;;
  deldir) del_scan_dir "$2" ;;
  *) echo "用法: dtbo.sh status|list|info <file>|backup [slot]|flash <file> [slot]|build <hz> [slot]|flashlocal [slot]|haslocal|autobackup|dirs|dirslist|adddir <目录>|deldir <目录>"; exit 9 ;;
esac
