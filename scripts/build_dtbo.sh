#!/system/bin/sh
# ============================================================

# ============================================================

DTB="$1"; OUT="$2"; TARGET="$3"

[ -z "$DTB" ] || [ -z "$OUT" ] && { echo "用法: sh build_dtbo.sh <dtb> <out.img> [size]"; exit 2; }
[ -f "$DTB" ] || { echo "!! 输入 DTB 不存在: $DTB"; exit 1; }

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

if [ -z "$TARGET" ]; then
  _slot=$(getprop ro.boot.slot_suffix 2>/dev/null); _slot=${_slot#_}
  [ -z "$_slot" ] && _slot=b
  TARGET=$(part_size64 "/dev/block/by-name/dtbo_$_slot")
fi
[ -z "$TARGET" ] && TARGET=$(part_size64 /dev/block/by-name/dtbo_b)
[ -z "$TARGET" ] && TARGET=$(part_size64 /dev/block/by-name/dtbo)
case "$TARGET" in ''|*[!0-9]*) TARGET=25165824 ;; esac

_SZ=$(stat -c %s "$DTB" 2>/dev/null) || { echo "!! 读取 DTB 大小失败"; exit 1; }
_TOTAL=$(( 64 + _SZ ))

_be32() {
  printf "\\x$(printf '%02x' $(( ($1 >> 24) & 255 )))\\x$(printf '%02x' $(( ($1 >> 16) & 255 )))\\x$(printf '%02x' $(( ($1 >> 8) & 255 )))\\x$(printf '%02x' $(( $1 & 255 )))"
}

rm -f "$OUT"
{
  # header 32B: magic total_size header_size=32 dt_entry_size=32 count=1 entries_off=32 page=4096 ver=0
  _be32 0xD7B7AB1E; _be32 $_TOTAL; _be32 32; _be32 32; _be32 1; _be32 32; _be32 4096; _be32 0
  # entry 32B: dt_size dt_offset=64 id=0 rev=0 + 16B zero
  _be32 $_SZ; _be32 64; _be32 0; _be32 0

  printf '\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0'
  cat "$DTB"
} > "$OUT" 2>/dev/null || { rm -f "$OUT"; echo "!! 写入失败"; exit 1; }

_CUR=$(stat -c %s "$OUT" 2>/dev/null)
if [ "$_CUR" -lt "$TARGET" ]; then
  truncate -s "$TARGET" "$OUT" 2>/dev/null || \
  dd if=/dev/zero of="$OUT" bs=1 count=1 seek=$(( TARGET - 1 )) conv=notrunc 2>/dev/null
fi

_MAGIC=$(od -A n -t x1 -N 4 "$OUT" 2>/dev/null | tr -d ' ')
if [ "$_MAGIC" != "d7b7ab1e" ]; then
  echo "!! 构建失败: magic=$_MAGIC (期望 d7b7ab1e)"; rm -f "$OUT"; exit 1
fi
_FINAL=$(stat -c %s "$OUT" 2>/dev/null)
echo "OK: $OUT ($_FINAL B, magic 校验通过)"
exit 0
