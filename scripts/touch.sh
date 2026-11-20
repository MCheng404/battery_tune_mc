#!/system/bin/sh

XBT=/data/adb/modules/battery_tune_mc
. $XBT/scripts/common.sh

TOUCH_DEVICES="dada haotian xuanyuan pudding pandora popsicle nezha"
TOUCH_DIR="$XBT/touch"
PATCH_DIR="$TOUCH_DIR/patched_files"
TARGET_DIR="/odm/firmware"
STATE="$XBT/state/touch_active"

mkdir -p "$PATCH_DIR" "$XBT/state" 2>/dev/null

mount_root() {
  awk -v t="$1" '$5 == t { print $4; exit }' /proc/self/mountinfo 2>/dev/null
}

touch_owned() {
  case "$1" in
    */battery_tune_mc/touch/patched_files/*) return 0 ;;
    *) return 1 ;;
  esac
}

detach_target() {
  _target=$1
  _i=0
  while [ "$_i" -lt 3 ]; do
    _r=$(mount_root "$_target")
    [ -n "$_r" ] || return 0
    umount "$_target" 2>/dev/null || umount -l "$_target" 2>/dev/null
    _i=$((_i+1))
    [ "$(mount_root "$_target")" = "$_r" ] && return 1
  done
  [ -n "$(mount_root "$_target")" ] && return 1
  return 0
}

touch_is_active() {
  for _d in $TOUCH_DEVICES; do
    for _k in nova syna; do
      _t="$TARGET_DIR/${_d}_${_k}_thp_config.ini"
      [ -f "$_t" ] || continue
      touch_owned "$(mount_root "$_t")" && return 0
    done
  done
  return 1
}

patch_one() {
  _t=$1
  [ -f "$_t" ] || return 0
  _n=$(basename "$_t")
  _p="$PATCH_DIR/$_n"
  _cur=$(mount_root "$_t")
  if touch_owned "$_cur"; then
    return 0
  fi
  if [ -n "$_cur" ]; then
    detach_target "$_t" || {
      log "touch: cannot detach existing mount $_t (root=$_cur)"
      return 1
    }
  fi
  cp -f "$_t" "$_p" 2>/dev/null || return 1
  sed -i \
    -e 's/ic_rate_normal=.*/ic_rate_normal=300/' \
    -e 's/rate_normal=.*/rate_normal=300/' \
    -e 's/ic_rate_game=.*/ic_rate_game=300/' \
    -e 's/rate_game=.*/rate_game=300/' \
    -e 's/ic_rate_vsync=.*/ic_rate_vsync=300/' \
    -e 's/rate_vsync=.*/rate_vsync=300/' \
    -e 's/low_fps_limit=.*/low_fps_limit=1/' \
    -e 's/normal_super_resolution=.*/normal_super_resolution=24/' \
    -e 's/game_super_resolution_default=.*/game_super_resolution_default=24/' \
    -e 's/game_super_resolution_0=.*/game_super_resolution_0=24/' \
    -e 's/game_super_resolution_1=.*/game_super_resolution_1=24/' \
    "$_p" 2>/dev/null || return 1
  chmod 644 "$_p" 2>/dev/null
  chown root:root "$_p" 2>/dev/null
  chcon --reference="$_t" "$_p" 2>/dev/null
  if mount --bind "$_p" "$_t" 2>>"$LOG"; then
    return 0
  fi
  log "touch: bind failed $_t"
  return 1
}

touch_start() {
  _found=0
  _ok=0
  for _d in $TOUCH_DEVICES; do
    for _k in nova syna; do
      _t="$TARGET_DIR/${_d}_${_k}_thp_config.ini"
      [ -f "$_t" ] || continue
      _found=1
      patch_one "$_t" && _ok=1
    done
  done
  if [ "$_ok" = "1" ]; then
    echo 1 > "$STATE" 2>/dev/null
    [ "$_found" = "1" ] && return 0
  fi
  echo 0 > "$STATE" 2>/dev/null
  [ "$_found" = "0" ] && return 0
  return 1
}

touch_stop() {
  _fail=0
  for _d in $TOUCH_DEVICES; do
    for _k in nova syna; do
      _t="$TARGET_DIR/${_d}_${_k}_thp_config.ini"
      [ -f "$_t" ] || continue
      [ -n "$(mount_root "$_t")" ] || continue
      detach_target "$_t" || {
        log "touch: unmount failed $_t"
        _fail=1
      }
    done
  done
  if touch_is_active; then
    echo 1 > "$STATE" 2>/dev/null
  else
    echo 0 > "$STATE" 2>/dev/null
  fi
  [ "$_fail" = "0" ] && return 0
  return 1
}

touch_status() {
  echo "touch_sample=$(cfg_get touch_sample 1)"
  if touch_is_active; then
    echo "touch_active=1"
  else
    echo "touch_active=0"
  fi
  echo "touch_rate=300"
}

case "$1" in
  on)
    cfg_set touch_sample 1 || exit 1
    touch_start
    exit $?
    ;;
  off)
    cfg_set touch_sample 0 || exit 1
    touch_stop
    exit $?
    ;;
  boot)
    [ "$(cfg_get touch_sample 1)" = "1" ] || exit 0
    touch_start >/dev/null 2>&1
    exit 0
    ;;
  isactive)
    if touch_is_active; then echo 1; else echo 0; fi
    ;;
  status)
    touch_status
    ;;
  *)
    echo "usage: $0 {on|off|boot|isactive|status}" >&2
    exit 2
    ;;
esac
