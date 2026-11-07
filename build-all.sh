#!/usr/bin/env bash
#
# tranG81 - build + release every device, then upload the ROM zip plus
# boot.img and vendor_boot.img of each device to Buzzheavier.
#
# Fixed order:  X6531 -> X6531B -> X6532 -> KL5 -> KL5n
# KL5n is last on purpose: its vendorsetup.sh applies the hardware/nxp/nfc
# patches when PATCH_NFC=true, so it must run after the clean builds.
#
# Every selected device is built once per GMS mode, in the fixed order
# vanilla -> gapps -> microg (microG always last): the mode selects a payload
# from device.mk (vendor/gapps or vendor/partner_gms), never both.
#
# Run it from the root of the LineageOS source tree (the dir holding
# build/envsetup.sh) or point ANDROID_ROOT at it:
#
#     ./build-all.sh                       # interactive TUI menu
#     ./build-all.sh -v userdebug -u yes    # non-interactive
#     ANDROID_ROOT=~/lineage ./build-all.sh
#
# Requires: bash 4+, curl, sha1sum, sha256sum, base64.  chmod +x this file first.
# Optional: ccache (--ccache), unzip (post-build rom radio check).  Every upload
# is sha256-verified against the hash the service reports, and the link expiry
# is printed.
#
set -uo pipefail

# ---------------------------------------------------------------- config -----

BUZZ_UPLOAD_BASE="${BUZZHEAVIER_UPLOAD_BASE:-https://w.buzzheavier.com}"
BUZZ_DOWNLOAD_BASE="${BUZZHEAVIER_DOWNLOAD_BASE:-https://buzzheavier.com}"
BUZZ_ACCOUNT_ID="${BUZZHEAVIER_ACCOUNT_ID:-}"
BUZZ_FOLDER_ID="${BUZZHEAVIER_FOLDER_ID:-}"

# status notifications: --notify URL (Discord/Slack webhook) or Telegram
# (--notify telegram:TOKEN:CHAT, or TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID)
NOTIFY_MODE="${NOTIFY_MODE:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

MAKE_TARGET="${MAKE_TARGET:-bacon}"
JOBS="${JOBS:-}"
WITH_XGSI_LOGS="${WITH_XGSI_LOGS:-}"
CCACHE_SIZE="${CCACHE_SIZE:-}"
MIN_FREE_GB="${MIN_FREE_GB:-40}"
# GMS passes per device, built in the fixed order vanilla -> gapps -> microg
# (microG always last).  Comma list from vanilla|gapps|microg, or "all".
GMS_MODES="${GMS_MODES:-vanilla}"

# images collected and uploaded next to the ROM zip (tagged per product);
# set EXTRA_IMAGES= to upload only the zip, add dtbo.img to include it.
EXTRA_IMAGES="${EXTRA_IMAGES-boot.img vendor_boot.img}"

# name | device tree | vendor tree | PRODUCT_DEVICE | PRODUCT_SYSTEM_DEVICE | radio dir | stock fingerprint
DEVICES=(
  "lineage_X6531|device/infinix/X6531|vendor/infinix/X6531|X6531|X6531|radio|Infinix/X6531-OP/Infinix-X6531:14/UP1A.231005.007/240820V1958:user/release-keys"
  "lineage_X6531B|device/infinix/X6531|vendor/infinix/X6531|X6531|X6531B|radio_x6531b|Infinix/X6531B-OP/Infinix-X6531B:14/UP1A.231005.007/260713V1136:user/release-keys"
  "lineage_X6532|device/infinix/X6532|vendor/infinix/X6532|X6532|X6532|radio|Infinix/X6532-OP/Infinix-X6532:14/UP1A.231005.007/240820V2071:user/release-keys"
  "lineage_KL5|device/tecno/KL5|vendor/tecno/KL5|KL5|KL5|radio|TECNO/KL5-OP/TECNO-KL5:14/UP1A.231005.007/240811V1304:user/release-keys"
  "lineage_KL5n|device/tecno/KL5|vendor/tecno/KL5|KL5|KL5n|radio_kl5n|TECNO/KL5n-OP/TECNO-KL5n:14/UP1A.231005.007/260710V887:user/release-keys"
)

VARIANT=""
REQUESTED="all"
DO_UPLOAD="no"
DO_NOTE="yes"
KEEP_GOING="no"
DRY_RUN="no"
CHECK_ONLY="no"
NO_BUILD="no"
NOTIFY_URL=""
ANDROID_ROOT="${ANDROID_ROOT:-}"

# LineageOS 23.x lunch() needs <product>-<release>-<variant>; the release (e.g.
# bp4a) is not optional.  Empty = auto-detect from the tree's pin file.
LUNCH_RELEASE="${LUNCH_RELEASE:-${TARGET_RELEASE:-}}"

RELEASE_ROOT=""
LOG_DIR=""
declare -a BUILT=() FAILED=() LINKS=() SELECTED=() COLLECTED=()
declare -a TIMING=() DIRTY=() REL_JSON=() LINK_BLOCKS=()
declare -a GMS_WANT=() GMS_MODE_LIST=()
GMS_MODE="" RELEASE_MODE_DIR=""

# filled in by bh_upload() for the caller
LAST_URL="" LAST_SHA256="" LAST_EXPIRY="" UPLOADED=0 EXPIRY_WARNED="no"
RUN_START=0

# ------------------------------------------------------------------ utils ----

c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'
c_bold=$'\033[1m'; c_rev=$'\033[7m'
say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n'  "$c_cyn" "$c_reset" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$c_yel" "$c_reset" "$*"; }
err()  { printf '%s[x]%s %s\n'  "$c_red" "$c_reset" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
tranG81 - build + release every device, then upload each ROM to Buzzheavier.

Fixed order:  X6531 -> X6531B -> X6532 -> KL5 -> KL5n
KL5n is last on purpose: its vendorsetup.sh applies the hardware/nxp/nfc
patches when PATCH_NFC=true, so it runs after the clean builds.

Run it from the root of the LineageOS source tree (the dir holding
build/envsetup.sh) or point ANDROID_ROOT at it:

    ./build-all.sh                        # interactive TUI menu
    ./build-all.sh -v userdebug -u yes     # non-interactive
    ANDROID_ROOT=~/lineage ./build-all.sh

The menu is a pure-bash full-screen TUI (arrow keys, checkboxes, colours) -
dialog, whiptail and fzf are not used and nothing has to be installed.  Piping
stdin or running without a terminal falls back to plain numbered prompts.

Before every build it sha1-checks each radio (firmware) image the vendor tree
declares for that product, so a wrong or mixed-up firmware is refused.  After
every build it re-checks that the produced ROM zip carries that product's own
radio images (by content sha1), then collects the ROM zip plus
boot.img/vendor_boot.img (put more in EXTRA_IMAGES, e.g. dtbo.img) and uploads
them; each upload is sha256-verified against the hash the service reports, and
the expiry is printed (anonymous links expire in a few days).  With Telegram
notify, a second message lists the download link of every uploaded file,
grouped per device and tagged rom / boot / vendor_boot / image.
Requires: bash 4+, curl, sha1sum, sha256sum, base64.  chmod +x this file first.

Options:
  -v, --variant user|userdebug|eng   build variant (default: interactive TUI)
      --release NAME                 lunch release config (e.g. bp4a); default
                                     reads vendor/lineage/vars/aosp_target_release
  -d, --devices LIST                 all | X6531,X6531B,X6532,KL5,KL5n
  -u, --upload | --no-upload         upload to Buzzheavier (default: --no-upload)
  -a, --account ID                   Buzzheavier account id (else anonymous)
      --folder ID                    upload into this Buzzheavier directory id
      --no-note                      skip the Buzzheavier note
      --jobs N                       make -jN (default: mka default)
      --ccache SIZE                  enable ccache and cap it at SIZE (e.g. 50G)
      --no-build                     skip building; re-upload collected artifacts
      --notify TARGET                status ping: a Discord/Slack webhook URL,
                                     telegram:TOKEN:CHAT, or a Telegram bot URL
      --telegram TOKEN:CHAT          shorthand for --notify telegram:TOKEN:CHAT
      --min-free GB                  refuse to start below this free space (default 40)
      --keep-going                   keep building the rest after a failure
      --dry-run                      print the plan, touch nothing
      --check-only                   run the firmware safety checks and stop
      --gms MODES                    GMS passes per device: vanilla (default),
                                     vanilla,gapps, vanilla,microg, or all
                                     (= vanilla,gapps,microg).  Built in that
                                     fixed order; microG is always last.
      --gapps                        shorthand for --gms vanilla,gapps
      --microg                       shorthand for --gms vanilla,microg
  -h, --help                         this text

Env: ANDROID_ROOT  BUZZHEAVIER_ACCOUNT_ID  BUZZHEAVIER_FOLDER_ID  JOBS  CCACHE_SIZE
     MIN_FREE_GB (default 40)  WITH_XGSI_LOGS  GMS_MODES  MAKE_TARGET  TARGET_RELEASE
     TELEGRAM_BOT_TOKEN  TELEGRAM_CHAT_ID  (notify via Telegram)
     EXTRA_IMAGES (default: boot.img vendor_boot.img; add dtbo.img here)

WITH_XGSI_LOGS=true installs the XGSI boot/dmesg log capture scripts into the
rom (the menu has a checkbox for it).  It is read from device.mk at
product-config time, so clear out/target/product/<device> before toggling it on
a tree that already built.

GMS modes: every selected device is built once per mode, in the fixed order
vanilla -> gapps -> microg.  vanilla is stock LineageOS; gapps bakes
MindTheGapps (vendor/gapps); microg bakes microG (vendor/partner_gms - LineageOS
already ships microG-only signature spoofing, so no frameworks patch is needed).
gapps and microG are mutually exclusive.  Both are read from device.mk at
product-config time, so the product out dir is cleared when the mode changes (a
per-product .trang81-gms stamp tracks it).  Artifacts land in
out/tranG81-releases/<variant>/<mode>/ and non-vanilla zips get a -GAPPS/-MICROG
suffix; boot images are collected on the vanilla pass only (identical across
modes).  The menu has a GMS row (keys g / left / right) to pick vanilla, +gapps,
+microG or all three.

Telegram: create a bot with @BotFather for the token, message the bot, then get
your chat id (e.g. https://api.telegram.org/bot<TOKEN>/getUpdates).  Then use
--notify telegram:<TOKEN>:<CHAT_ID> (or export TELEGRAM_BOT_TOKEN and
TELEGRAM_CHAT_ID, which enables Telegram notify on its own).  On success it
also posts the per-file download links (grouped per device / category); a
build failure posts the error tail and uploads the full build log to the chat.
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# seconds -> 1h02m03s
human_time() {
  local s="$1"
  if (( s >= 3600 )); then printf '%dh%02dm%02ds' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
  elif (( s >= 60 )); then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"; fi
}

# minimal JSON string escaping
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
  printf '"%s"' "$s"
}

# ------------------------------------------------------------------- gms ----

# fold a requested mode list (comma/space separated, repeated) into the fixed
# build order vanilla -> gapps -> microg, de-duplicated.  "all" = the three
# passes, "none"/"vanilla" = the vanilla pass only.  (gapps/microG build on top
# of the LineageOS base, so vanilla is always kept.)  Sets GMS_MODE_LIST.
normalize_gms() {
  local t
  local -a src=() part=()
  local -A sel=()
  for t in "$@"; do
    part=()
    IFS=', ' read -r -a part <<<"$t"
    src+=("${part[@]+"${part[@]}"}")
  done
  for t in "${src[@]+"${src[@]}"}"; do
    [[ -n "$t" ]] || continue
    case "$t" in
      all)          sel[vanilla]=1; sel[gapps]=1; sel[microg]=1 ;;
      none|vanilla) sel[vanilla]=1 ;;
      gapps)        sel[gapps]=1 ;;
      microg)       sel[microg]=1 ;;
      *)            die "bad --gms value '$t' (use vanilla|gapps|microg|all)" ;;
    esac
  done
  # gapps/microG are baked on top of the LineageOS base, so the vanilla pass is
  # always kept (and always runs first).
  sel[vanilla]=1
  GMS_MODE_LIST=()
  for t in vanilla gapps microg; do
    [[ -n "${sel[$t]:-}" ]] && GMS_MODE_LIST+=("$t")
  done
  [[ ${#GMS_MODE_LIST[@]} -gt 0 ]] || GMS_MODE_LIST=(vanilla)
}

# export the env device.mk reads to pick the GMS payload for this pass.
set_gms_env() {
  unset WITH_GAPPS WITH_MICROG
  case "$1" in
    gapps)  export WITH_GAPPS=true ;;
    microg) export WITH_MICROG=true ;;
  esac
}

# upper-case tag used for artifact suffixes.
gms_label() { case "$1" in gapps) echo GAPPS ;; microg) echo MICROG ;; *) echo vanilla ;; esac; }

# device.mk reads WITH_GAPPS/WITH_MICROG at product-config time, so a product
# built in another mode must be re-configured from scratch.  Stamp each product
# out dir with the mode it was built for and wipe it when that changes.  A
# missing stamp counts as vanilla, so an existing non-GMS out survives the first
# vanilla pass without a full rebuild.
ensure_gms_out() {
  local device="$1" mode="$2" out stamp cur
  out="$ANDROID_ROOT/out/target/product/$device"
  stamp="$out/.trang81-gms"
  [[ -d "$out" ]] || return 0
  cur=""
  [[ -r "$stamp" ]] && cur="$(<"$stamp")"
  [[ -n "$cur" ]] || cur="vanilla"
  if [[ "$cur" != "$mode" ]]; then
    info "$device: gms mode '$cur' -> '$mode' - clearing out/target/product/$device"
    rm -rf "$out" || return 1
  fi
  mkdir -p "$out" || return 1
  printf '%s' "$mode" > "$stamp"
}

# put microG's modules in their own namespace so gapps' GmsCore doesn't clash
ensure_microg_namespace() {
  local dir="$ANDROID_ROOT/vendor/partner_gms" bp
  [[ -d "$dir" ]] || return 0
  bp="$dir/Android.bp"
  if [[ -e "$bp" ]]; then
    grep -q 'soong_namespace' "$bp" \
      || warn "$bp exists without a soong_namespace - the gapps GmsCore collision may return"
    return 0
  fi
  printf 'soong_namespace {\n}\n' > "$bp" 2>/dev/null \
    || { warn "could not write $bp"; return 0; }
  info "soong    : namespaced vendor/partner_gms (microG) to avoid the gapps GmsCore clash"
}

# -------------------------------------------------------------- preflight ----

# refuse to start when out/ has less free space than MIN_FREE_GB.
check_disk() {
  local target="$ANDROID_ROOT/out" avail_kb avail_gb
  [[ -d "$target" ]] || target="$ANDROID_ROOT"
  avail_kb=$(df -Pk "$target" 2>/dev/null | awk 'NR==2{print $4}')
  if [[ -z "$avail_kb" ]]; then
    warn "could not read free space for $target - disk check skipped"
    return 0
  fi
  avail_gb=$((avail_kb / 1024 / 1024))
  if (( avail_gb < MIN_FREE_GB )); then
    err "low disk: ${avail_gb}G free on $target, need >= ${MIN_FREE_GB}G"
    err "   free some space, or lower MIN_FREE_GB / --min-free"
    return 1
  fi
  ok "disk: ${avail_gb}G free on $target (>= ${MIN_FREE_GB}G)"
}

# enable ccache when a size was requested.  AOSP's make honours USE_CCACHE.
setup_ccache() {
  [[ -n "$CCACHE_SIZE" ]] || return 0
  local cexe
  cexe=$(command -v ccache 2>/dev/null || true)
  export USE_CCACHE=1
  [[ -n "$cexe" ]] && export CCACHE_EXEC="$cexe"
  if [[ -n "$cexe" ]]; then
    if ccache -M "$CCACHE_SIZE" >/dev/null 2>&1; then
      ok "ccache enabled, max ${CCACHE_SIZE} (dir ${CCACHE_DIR:-${HOME:-~}/.ccache})"
    else
      warn "ccache -M $CCACHE_SIZE failed - continuing without the cap"
    fi
  else
    warn "ccache not on PATH - USE_CCACHE=1 is set but caching will not work"
  fi
}

# uncommitted changes in a tree make the build unreproducible - warn, never fatal.
check_dirty() {
  local tree="$1"
  local dir="$ANDROID_ROOT/$tree" st
  [[ -d "$dir/.git" ]] || return 0
  have git || return 0
  st=$(git -C "$dir" status --porcelain 2>/dev/null)
  if [[ -n "$st" ]]; then
    warn "$tree has uncommitted changes:"
    printf '%s\n' "$st" | head -n 6 | sed 's/^/   /'
    DIRTY+=("$tree")
  fi
  return 0
}

# ------------------------------------------------------------ firmware ------

# print "<rel> <sha1>" for every radio image the vendor tree declares for this
# product, parsed out of its Android.mk add-radio-file-sha1-checked list.
radio_image_list() {
  local vendortree="$1" radiodir="$2"
  sed -n "s/.*add-radio-file-sha1-checked,\($radiodir\/[^,]*\),\([0-9a-f]\{40\}\).*/\1 \2/p" \
    "$ANDROID_ROOT/$vendortree/Android.mk"
}

# sha1-check every radio image the vendor tree declares for this product.
verify_radio() {
  local vendortree="$1" radiodir="$2"
  local mkv="$ANDROID_ROOT/$vendortree/Android.mk"
  local count=0 bad=0 rel sha file actual

  [[ -f "$mkv" ]] || { err "no $vendortree/Android.mk"; return 1; }

  while read -r rel sha; do
    [[ -n "$rel" ]] || continue
    count=$((count + 1))
    file="$ANDROID_ROOT/$vendortree/$rel"
    if [[ ! -f "$file" ]]; then
      err "firmware missing: $vendortree/$rel"
      bad=$((bad + 1)); continue
    fi
    actual=$(sha1sum "$file" | awk '{print $1}')
    if [[ "$actual" == "$sha" ]]; then
      ok "firmware ok   $rel"
    else
      err "firmware WRONG: $rel"
      err "   expected $sha"
      err "   actual   $actual"
      bad=$((bad + 1))
    fi
  done < <(radio_image_list "$vendortree" "$radiodir")

  if [[ "$count" -eq 0 ]]; then
    err "vendor tree declares no '$radiodir/' firmware - wrong tree for this product?"
    return 1
  fi
  [[ "$bad" -eq 0 ]] || return 1
  info "$count radio images verified for $vendortree/$radiodir/"
}

# the tree pairing itself: device tree <-> vendor tree <-> product.
verify_trees() {
  local product="$1" devtree="$2" vendortree="$3" device="$4" radiodir="$5"
  local short="${product#lineage_}" fail=0 bn

  for d in "$ANDROID_ROOT/$devtree" "$ANDROID_ROOT/$vendortree"; do
    [[ -d "$d" ]] || { err "missing tree: $d"; fail=1; }
  done
  [[ "$fail" -eq 0 ]] || return 1

  if [[ ! -f "$ANDROID_ROOT/$devtree/lineage_$short.mk" ]]; then
    err "missing product makefile: $devtree/lineage_$short.mk"
    fail=1
  fi

  if ! grep -qF "include $vendortree/BoardConfigVendor.mk" "$ANDROID_ROOT/$devtree/BoardConfig.mk"; then
    err "$devtree/BoardConfig.mk does not include $vendortree/BoardConfigVendor.mk"
    err "   -> device tree and vendor tree do not match"
    fail=1
  fi

  bn=$(ls "$ANDROID_ROOT/$vendortree"/*-vendor.mk 2>/dev/null | head -n1)
  if [[ -z "$bn" ]] || ! grep -qF "$vendortree" "$bn"; then
    err "$vendortree has no *-vendor.mk pointing at $vendortree"
    fail=1
  fi

  if ! grep -qF "ifeq (\$(TARGET_DEVICE),$device)" "$ANDROID_ROOT/$vendortree/Android.mk"; then
    err "$vendortree/Android.mk is not guarded for TARGET_DEVICE=$device"
    fail=1
  fi

  [[ "$fail" -eq 0 ]] || return 1
  verify_radio "$vendortree" "$radiodir"
}

# after the build: the produced ROM must carry this product's stock fingerprint.
verify_rom() {
  local device="$1" fp="$2" out props p found=0 any=0 seen=""

  out="$ANDROID_ROOT/out/target/product/$device"
  if [[ ! -d "$out" ]]; then
    warn "no output dir for $device yet - rom check skipped"
    return 0
  fi
  props=$(find "$out" -maxdepth 4 -name build.prop -print 2>/dev/null)

  while read -r p; do
    [[ -n "$p" ]] || continue
    grep -qE '^ro\.(system\.|vendor\.|odm\.|product\.)?build\.fingerprint=' "$p" || continue
    any=1
    if grep -qF "$fp" "$p"; then
      found=1
      ok "rom fingerprint ok   ${p#$ANDROID_ROOT/}"
    fi
    seen+="$(grep -hE '^ro\.build\.fingerprint=' "$p" | head -n1) "
  done <<<"$props"

  if [[ "$found" -eq 1 ]]; then
    return 0
  elif [[ "$any" -eq 1 ]]; then
    err "rom fingerprint mismatch for $device"
    err "   expected $fp"
    err "   found    $seen"
    return 1
  fi
  warn "no build.prop with a fingerprint under out/target/product/$device - skipped"
  return 0
}

# after the build: the produced OTA must carry *this* product's own radio
# images.  Each declared image is matched by basename anywhere in the zip and
# its content sha1 compared, so another product's firmware cannot end up in
# this zip without being caught.  A missing entry is only a warning (the
# add-radio-file-sha1-checked gate already checked it at build time); a present
# entry with the wrong sha1 is fatal and stops the upload.
verify_zip_radio() {
  local zip="$1" vendortree="$2" radiodir="$3"
  local rel exp name entry got n=0 bad=0

  if [[ -z "$zip" || ! -f "$zip" ]]; then
    warn "no rom zip to check for $vendortree/$radiodir firmware - skipped"
    return 0
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    warn "unzip not on PATH - post-build rom radio check skipped"
    return 0
  fi

  while read -r rel exp; do
    [[ -n "$rel" ]] || continue
    n=$((n + 1))
    name="$(basename "$rel")"
    entry="$(unzip -Z1 "$zip" 2>/dev/null | grep -iE "(^|/)$name\$" | head -n1)"
    if [[ -z "$entry" ]]; then
      warn "rom radio $name: not packaged in the rom zip (build-time sha1 check still applies)"
      continue
    fi
    got="$(unzip -p "$zip" "$entry" 2>/dev/null | sha1sum | awk '{print $1}')"
    if [[ "$got" == "$exp" ]]; then
      ok "rom radio ok   $name"
    else
      err "rom radio WRONG: $name ($entry in ${zip##*/})"
      err "   expected $exp"
      err "   actual   $got"
      bad=$((bad + 1))
    fi
  done < <(radio_image_list "$vendortree" "$radiodir")

  if [[ "$n" -eq 0 ]]; then
    warn "no '$radiodir/' firmware declared - post-build rom radio check skipped"
    return 0
  fi
  [[ "$bad" -eq 0 ]] || return 1
  return 0
}

# ----------------------------------------------------------------- upload ----

bh_upload() {
  local file="$1" name="$2" note="${3:-}"
  local url="$BUZZ_UPLOAD_BASE" id body code resp hdr=()
  local srv_sha srv_size lv_sha lv_size

  [[ -n "$BUZZ_FOLDER_ID" ]] && url="$url/$BUZZ_FOLDER_ID"
  url="$url/$name"
  if [[ -n "$note" && "$DO_NOTE" == "yes" ]]; then
    url="$url?note=$(printf '%s' "$note" | base64 | tr -d '\n')"
  fi
  [[ -n "$BUZZ_ACCOUNT_ID" ]] && hdr=(-H "Authorization: Bearer $BUZZ_ACCOUNT_ID")

  info "uploading $name ($(du -h "$file" | cut -f1))"
  if [[ "$DRY_RUN" == "yes" ]]; then
    say "    curl -T $file ${hdr[*]:-} $url"
    LINKS+=("<dry-run> $url")
    LAST_URL="$url"; LAST_SHA256=""; LAST_EXPIRY=""
    return 0
  fi

  resp=$(curl -sS --retry 3 --retry-delay 2 --retry-all-errors -o - -w $'\n%{http_code}' \
         -T "$file" "${hdr[@]+"${hdr[@]}"}" "$url") || { err "curl failed for $name"; return 1; }
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ "$code" != "200" && "$code" != "201" ]]; then
    err "upload HTTP $code: $body"
    return 1
  fi

  id=$(printf '%s' "$body" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
  if [[ -z "$id" ]]; then
    id=$(printf '%s' "$body" | tr -dc 'A-Za-z0-9_-')
    [[ ${#id} -ge 6 && ${#id} -le 32 ]] || id=""
  fi
  if [[ -z "$id" ]]; then
    warn "uploaded but could not parse the file id"
    say "    raw response: $body"
    LINKS+=("? $name (HTTP $code)")
    LAST_URL=""; LAST_SHA256=""; LAST_EXPIRY=""
    return 0
  fi

  LAST_URL="$BUZZ_DOWNLOAD_BASE/$id"
  LAST_SHA256=$(printf '%s' "$body" | grep -oE '"sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' | head -n1 | sed -E 's/.*"([0-9a-f]{64})".*/\1/')
  LAST_EXPIRY=$(printf '%s' "$body" | grep -oE '"expiry"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
  srv_size=$(printf '%s' "$body" | grep -oE '"size"[[:space:]]*:[[:space:]]*[0-9]+' | head -n1 | grep -oE '[0-9]+')

  # the API returns the real hash of the stored file, so the upload can be checked
  if [[ -n "$LAST_SHA256" ]]; then
    lv_sha=$(sha256sum "$file" | awk '{print $1}')
    if [[ "$lv_sha" == "$LAST_SHA256" ]]; then
      ok "sha256 verified  $name"
    else
      err "sha256 MISMATCH for $name - upload is corrupt"
      err "   local  $lv_sha"
      err "   server $LAST_SHA256"
      return 1
    fi
  else
    warn "$name: server reported no sha256 - upload not verified"
  fi
  if [[ -n "$srv_size" ]]; then
    lv_size=$(wc -c < "$file")
    if [[ "$lv_size" != "$srv_size" ]]; then
      err "size mismatch for $name (local $lv_size, server $srv_size)"
      return 1
    fi
  fi

  ok "$LAST_URL"
  if [[ -n "$LAST_EXPIRY" ]]; then
    say "    expires $LAST_EXPIRY"
    if [[ -z "$BUZZ_ACCOUNT_ID" && "$EXPIRY_WARNED" != "yes" ]]; then
      warn "anonymous upload: links expire $LAST_EXPIRY - use -a <account id> for longer retention"
      EXPIRY_WARNED="yes"
    fi
  fi
  LINKS+=("$LAST_URL $name")
  UPLOADED=$((UPLOADED + 1))
}

# POST a one-line status to a Discord/Slack webhook or a Telegram chat (best
# effort).  Telegram is used when --notify telegram[:TOKEN:CHAT] is given or
# both TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID are set; otherwise the plain
# webhook payload {"content":..,"text":..} is posted to NOTIFY_URL.
notify() {
  local msg="$1" payload="" url=""
  if [[ "$NOTIFY_MODE" == "telegram" ]]; then
    [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || {
      warn "telegram notify: need --notify telegram:TOKEN:CHAT or TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID"; return 0; }
    url="https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage"
    payload=$(printf '{"chat_id":%s,"text":%s,"disable_web_page_preview":true}' \
      "$(json_str "$TELEGRAM_CHAT_ID")" "$(json_str "$msg")")
  elif [[ -n "$NOTIFY_URL" ]]; then
    url="$NOTIFY_URL"
    payload=$(printf '{"content":%s,"text":%s}' "$(json_str "$msg")" "$(json_str "$msg")")
  else
    return 0
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then info "notify (dry-run): $msg"; return 0; fi
  if curl -sS -o /dev/null --max-time 20 -X POST -H 'Content-Type: application/json' \
       --data "$payload" "$url" 2>/dev/null; then
    ok "notified"
  else
    warn "notify failed"
  fi
}

# On failure, put the build log in the chat.  Telegram gets the file itself
# (sendDocument, <=50 MB) with the error tail as caption; a plain webhook can
# only carry text, so it gets the tail.  Best effort, never fatal.
notify_log() {
  local file="$1" caption="${2:-build log}" tail url size
  [[ -n "$NOTIFY_MODE" ]] || return 0
  [[ -f "$file" ]] || return 0

  tail=$(grep -nE 'FAILED:|error:|fatal error|ninja: build stopped' "$file" 2>/dev/null | tail -n 15)
  [[ -n "$tail" ]] || tail=$(tail -n 15 "$file" 2>/dev/null)

  if [[ "$NOTIFY_MODE" != "telegram" ]]; then
    [[ -n "$NOTIFY_URL" ]] || return 0
    notify "$caption
$tail"
    return 0
  fi

  [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || return 0
  size=$(wc -c < "$file")
  if (( size > 50 * 1024 * 1024 )); then
    warn "log ${size}B is too big for Telegram - sending the error tail only"
    notify "$caption
$tail"
    return 0
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then info "notify-log (dry-run): $file"; return 0; fi
  url="https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument"
  if curl -sS -o /dev/null --max-time 180 \
       -F "chat_id=$TELEGRAM_CHAT_ID" \
       -F "caption=${caption:0:1000}" \
       -F "document=@$file" "$url" 2>/dev/null; then
    ok "notified (log: ${file##*/})"
  else
    warn "log upload failed - sending the error tail only"
    notify "$caption
$tail"
  fi
}

# classify an uploaded file for the link notification.
link_category() {
  case "$1" in
    *.zip)             echo rom ;;
    vendor_boot-*.img) echo vendor_boot ;;
    boot-*.img)        echo boot ;;
    *.img)             echo image ;;
    *)                 echo file ;;
  esac
}

# Send the download link of every uploaded file, grouped per product and
# tagged by category (rom / boot / vendor_boot / image).  Telegram caps a
# message at 4096 chars, so whole per-product blocks are packed into as few
# messages as possible.  Best effort, never fatal.
notify_links() {
  local header="tranG81 $VARIANT - download links (${#LINK_BLOCKS[@]} product(s)):"
  [[ -n "$NOTIFY_MODE" && ${#LINK_BLOCKS[@]} -gt 0 ]] || return 0

  local b msg all=""
  if [[ "$NOTIFY_MODE" != "telegram" ]]; then
    for b in "${LINK_BLOCKS[@]}"; do all+="$header"$'\n'"$b"$'\n'; header=""; done
    [[ -n "$all" ]] && notify "$all"
    return 0
  fi

  msg="$header"
  for b in "${LINK_BLOCKS[@]}"; do
    if (( ${#msg} + ${#b} + 1 > 3900 )); then notify "$msg"; msg="$b";
    else msg+=$'\n'"$b"; fi
  done
  [[ -n "$msg" ]] && notify "$msg"
}

# --notify accepts a webhook URL, "telegram", "telegram:TOKEN:CHAT", or a
# copy-pasted https://api.telegram.org/bot<token>/sendMessage URL.
parse_notify() {
  local v="$1" spec
  NOTIFY_URL=""
  case "$v" in
    "" ) NOTIFY_MODE="" ;;
    telegram|telegram:*)
      NOTIFY_MODE="telegram"
      spec="${v#telegram}"; spec="${spec#:}"
      if [[ -n "$spec" ]]; then
        TELEGRAM_BOT_TOKEN="${spec%:*}"      # bot id:secret (keep the colon)
        TELEGRAM_CHAT_ID="${spec##*:}"       # everything after the last colon
      fi ;;
    *api.telegram.org/bot*)
      NOTIFY_MODE="telegram"
      spec="${v%%\?*}"; spec="${spec#*api.telegram.org/bot}"; TELEGRAM_BOT_TOKEN="${spec%%/*}"
      if [[ "$v" == *chat_id=* ]]; then
        spec="${v#*chat_id=}"; TELEGRAM_CHAT_ID="${spec%%&*}"
      fi ;;
    * ) NOTIFY_MODE="webhook"; NOTIFY_URL="$v" ;;
  esac
}

# ------------------------------------------------------------------ build ----

# PATCH_NFC patches hardware/nxp/nfc when envsetup.sh runs; confirm the patches
# landed, otherwise KL5n would quietly build without NFC.
verify_nfc_patches() {
  local devtree="$1"
  local hal="$ANDROID_ROOT/hardware/nxp/nfc"
  local pdir="$ANDROID_ROOT/$devtree/patches/nfc"
  local p n=0 miss=0

  if [[ ! -d "$hal" ]]; then
    warn "hardware/nxp/nfc missing - NFC patch check skipped"
    return 0
  fi
  if [[ ! -d "$pdir" ]]; then
    warn "$devtree/patches/nfc missing - NFC patch check skipped"
    return 0
  fi

  for p in "$pdir"/[0-9][0-9][0-9][0-9]-*.patch; do
    [[ -f "$p" ]] || continue
    n=$((n + 1))
    if git -C "$hal" apply --reverse --check "$p" 2>/dev/null \
       || patch -p1 --reverse --dry-run --fuzz=3 -d "$hal" -i "$p" >/dev/null 2>&1; then
      ok "nfc patch applied     $(basename "$p")"
    else
      err "nfc patch NOT applied: $(basename "$p")"
      miss=$((miss + 1))
    fi
  done

  if [[ "$n" -eq 0 ]]; then
    warn "no NFC patches found in $devtree/patches/nfc"
    return 0
  fi
  [[ "$miss" -eq 0 ]] || return 1
  info "$n NFC patches verified"
}

# a device build runs for an hour; surface why it died instead of "see the log".
show_build_errors() {
  local log="$1" hits
  [[ -f "$log" ]] || return 0
  hits=$(grep -nE 'FAILED:|error:|fatal error|ninja: build stopped' "$log" 2>/dev/null | tail -n 12)
  if [[ -n "$hits" ]]; then
    say "   ---- last errors (${log##*/}) ----"
    printf '%s\n' "$hits" | sed 's/^/   /'
  else
    say "   ---- no error lines; tail of ${log##*/} ----"
    tail -n 8 "$log" | sed 's/^/   /'
  fi
}

# LineageOS 23.x lunch() wants a release config (bp4a, trunk_staging, ...) that is
# not optional.  Prefer --release / TARGET_RELEASE, else the pin LineageOS ships
# in vendor/lineage/vars/aosp_target_release (what its own breakfast uses), else
# a release the tree lists for this product, else AOSP's default.
resolve_release() {
  local product="$1" f rel
  if [[ -n "$LUNCH_RELEASE" ]]; then printf '%s' "$LUNCH_RELEASE"; return 0; fi
  f="$ANDROID_ROOT/vendor/lineage/vars/aosp_target_release"
  if [[ -r "$f" ]]; then
    rel=$(sed -n 's/^[[:space:]]*aosp_target_release[[:space:]]*=[[:space:]]*\([A-Za-z0-9_.-]*\).*/\1/p' "$f" | tail -n1)
    [[ -n "$rel" ]] && { printf '%s' "$rel"; return 0; }
  fi
  if declare -F list_releases >/dev/null 2>&1; then
    rel=$(list_releases "$product" 2>/dev/null | tr ' \t' '\n\n' | grep -E '^[A-Za-z0-9_.-]+$' | head -n1)
    [[ -n "$rel" ]] && { printf '%s' "$rel"; return 0; }
  fi
  printf '%s' 'trunk_staging'
}

run_build() {
  local product="$1" variant="$2" nfc="$3" devtree="$4" log="$5"
  local rc gmsenv=""

  [[ -n "$LUNCH_RELEASE" ]] || LUNCH_RELEASE="$(resolve_release "$product")"

  # device.mk reads these at product-config time to pick the GMS payload.
  set_gms_env "$GMS_MODE"
  [[ "$GMS_MODE" == gapps ]]  && gmsenv="WITH_GAPPS=true"
  [[ "$GMS_MODE" == microg ]] && gmsenv="WITH_MICROG=true"

  if [[ "$DRY_RUN" == "yes" ]]; then
    say "    cd $ANDROID_ROOT"
    say "    source build/envsetup.sh   (PATCH_NFC=$([[ "$nfc" == 1 ]] && echo true || echo unset)${gmsenv:+ $gmsenv})"
    say "    lunch ${product} ${LUNCH_RELEASE} ${variant}"
    say "    mka ${MAKE_TARGET}${JOBS:+ -j$JOBS}"
    return 0
  fi

  cd "$ANDROID_ROOT" || return 1

  if [[ "$nfc" == "1" ]]; then
    export PATCH_NFC=true            # vendorsetup.sh applies hardware/nxp/nfc patches
  else
    unset PATCH_NFC
  fi
  [[ -n "$WITH_XGSI_LOGS" ]] && export WITH_XGSI_LOGS

  # build/envsetup.sh is not nounset-safe - it reads $TOP before defaulting it, so
  # our own set -u makes it die with "TOP: unbound variable".  Turn nounset off
  # while the sourced envsetup, its lunch()/mka() helpers and the make run.
  set +u
  # shellcheck disable=SC1091
  source build/envsetup.sh >/dev/null
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    lunch "$product" "$LUNCH_RELEASE" "$variant"; rc=$?
    if [[ "$rc" -ne 0 ]]; then
      warn "lunch $product $LUNCH_RELEASE $variant failed - pick the release with"
      warn "   --release NAME (see vendor/lineage/vars/aosp_target_release)"
    fi
  fi
  if [[ "$rc" -eq 0 && "$nfc" == "1" ]]; then
    verify_nfc_patches "$devtree" || rc=1
  fi

  local -a mk=(mka "$MAKE_TARGET")
  [[ -n "$JOBS" ]] && mk+=("-j$JOBS")
  if [[ "$rc" -eq 0 ]]; then
    say "+ ${mk[*]}   (log: ${log#$ANDROID_ROOT/})"
    "${mk[@]}" 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"
  fi
  set -u
  return "$rc"
}

# move the freshly built artifacts out of the shared out dir with unique names.
# Fills COLLECTED (rom zip first, then the boot images). The zip is fatal if
# missing; a missing boot image is only a warning, so the ROM still ships.
collect_artifacts() {
  local device="$1" product="$2" variant="$3"
  local out="$ANDROID_ROOT/out/target/product/$device"
  local dir="$RELEASE_ROOT/$variant/$GMS_MODE"
  local tag stem dest zip img name msuf
  COLLECTED=()

  tag="${product#lineage_}"
  mkdir -p "$dir" || return 1

  msuf=""
  [[ "$GMS_MODE" != vanilla ]] && msuf="-$(gms_label "$GMS_MODE")"

  zip=$(ls -1t "$out"/lineage*.zip 2>/dev/null | head -n1)
  if [[ -z "$zip" || ! -f "$zip" ]]; then
    err "no lineage*.zip under out/target/product/$device"
    return 1
  fi
  stem="$(basename "$zip")"; stem="${stem%.zip}"
  case "$stem" in
    *"$tag"*) dest="${stem}${msuf}.zip" ;;
    *)        dest="${stem}-${tag}${msuf}.zip" ;;
  esac
  cp -f "$zip" "$dir/$dest" || return 1
  COLLECTED+=("$dir/$dest")

  # boot.img / vendor_boot.img carry no system apps, so they are identical
  # across GMS modes - collect them on the vanilla pass only, else the same file
  # would be uploaded once per mode.  (Both products of a shared out dir write
  # the same file name there, so tag every copy with the product.)
  [[ "$GMS_MODE" == vanilla ]] || return 0
  for img in $EXTRA_IMAGES; do
    if [[ ! -f "$out/$img" ]]; then
      warn "$img not produced for $product - skipped"
      continue
    fi
    name="${img%.img}-${tag}.img"
    cp -f "$out/$img" "$dir/$name" || return 1
    COLLECTED+=("$dir/$name")
  done
}

# --no-build: reuse the artifacts already sitting in the release dir.
collect_existing() {
  local product="$1" variant="$2"
  local tag="${product#lineage_}"
  local dir="$RELEASE_ROOT/$variant/$GMS_MODE" f
  COLLECTED=()
  if [[ ! -d "$dir" ]]; then
    err "no release dir $dir - build once, or point at the right --variant"
    return 1
  fi
  for f in "$dir"/*.zip; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" =~ (^|[-_])"$tag"([-_.]|$) ]] && COLLECTED+=("$f")
  done
  for f in $EXTRA_IMAGES; do
    f="$dir/${f%.img}-${tag}.img"
    [[ -f "$f" ]] && COLLECTED+=("$f")
  done
  if [[ ${#COLLECTED[@]} -eq 0 ]]; then
    err "no $tag artifacts in $dir"
    return 1
  fi
  return 0
}

# accumulate one device/mode object for releases-<variant>.json.
# args: product mode sysdev elapsed status then "name|url|sha256|expiry" ...
add_json_record() {
  local product="$1" mode="$2" sysdev="$3" elapsed="$4" status="$5"; shift 5
  local rec f name url sha exp first=1
  rec="    {\"product\":$(json_str "$product"),\"gms_mode\":$(json_str "$mode")"
  rec+=",\"system_device\":$(json_str "$sysdev")"
  rec+=",\"elapsed_seconds\":${elapsed},\"status\":$(json_str "$status"),\"files\":["
  for f in "$@"; do
    IFS='|' read -r name url sha exp <<<"$f"
    [[ "$first" == "1" ]] || rec+=","
    first=0
    rec+="{\"name\":$(json_str "$name"),\"url\":$(json_str "$url"),\"sha256\":$(json_str "$sha"),\"expiry\":$(json_str "$exp")}"
  done
  rec+="]}"
  REL_JSON+=("$rec")
}

# --------------------------------------------------------------- menu ---------

ask() { local p="$1" d="$2" a; read -r -p "$p [$d]: " a </dev/tty; printf '%s' "${a:-$d}"; }

# Pure-bash full-screen TUI: every key (arrows included) arrives through
# read -rsn1, so nothing has to be installed - no dialog, whiptail or fzf.
# The tty state is saved up front and restored on every exit path.
TUI_FOCUS=0
TUI_VARIANT="user"
TUI_UPLOAD="yes"
TUI_XGSI="no"
TUI_GMS=0
TUI_STATUS=""
TUI_STTY=""
TUI_VARIANTS=(user userdebug eng)
TUI_GMS_MODES=(vanilla "vanilla,gapps" "vanilla,microg" "vanilla,gapps,microg")
TUI_GMS_LABELS=(vanilla "vanilla+gapps" "vanilla+microg" "all (3)")
declare -a TUI_SEL=()

tui_cleanup() {
  [[ -n "$TUI_STTY" ]] && stty "$TUI_STTY" </dev/tty 2>/dev/null
  TUI_STTY=""
  printf '\033[?25h\033[0m'
  trap - INT TERM
}

# one keypress -> a symbolic name (arrows are ESC [ A/B/C/D)
tui_key() {
  local k a b
  IFS= read -rsn1 k </dev/tty || return 1
  if [[ "$k" == $'\033' ]]; then
    IFS= read -rsn1 -t 0.05 a </dev/tty || true
    IFS= read -rsn1 -t 0.05 b </dev/tty || true
    case "$a$b" in
      '[A'|'OA') printf 'up' ;;
      '[B'|'OB') printf 'down' ;;
      '[C'|'OC') printf 'right' ;;
      '[D'|'OD') printf 'left' ;;
      *)         printf 'quit' ;;
    esac
    return 0
  fi
  case "$k" in
    '')   printf 'enter' ;;
    ' ')  printf 'space' ;;
    q|Q)  printf 'quit' ;;
    h|H)  printf 'left' ;;
    l|L)  printf 'right' ;;
    j|J)  printf 'down' ;;
    k|K)  printf 'up' ;;
    a|A)  printf 'all' ;;
    n|N)  printf 'none' ;;
    u|U)  printf 'upload' ;;
    x|X)  printf 'xgsi' ;;
    g|G)  printf 'gms' ;;
    *)    printf 'noop' ;;
  esac
}

tui_cycle() {   # move the variant by $1 (+1 / -1)
  local dir="$1" i
  for i in "${!TUI_VARIANTS[@]}"; do
    [[ "${TUI_VARIANTS[$i]}" == "$TUI_VARIANT" ]] && break
  done
  i=$(((i + dir + ${#TUI_VARIANTS[@]}) % ${#TUI_VARIANTS[@]}))
  TUI_VARIANT="${TUI_VARIANTS[$i]}"
}

tui_mark() { (( $1 == TUI_FOCUS )) && printf " ${c_bold}>${c_reset} " || printf '   '; }

tui_render() {
  local n=${#DEVICES[@]} i lab short row
  printf '\033[H'
  printf '  %s%stranG81%s - build + release\033[K\n' "$c_cyn" "$c_bold" "$c_reset" "$c_reset"
  printf '  %s%s%s\033[K\n' "$c_cyn" '────────────────────────────────────────────────────────────' "$c_reset"
  printf '\033[K\n'

  printf '   %svariant%s  ' "$c_cyn" "$c_reset"
  for lab in "${TUI_VARIANTS[@]}"; do
    if [[ "$lab" == "$TUI_VARIANT" ]]; then printf '%s %s %s ' "$c_rev" "$lab" "$c_reset"
    else printf ' %s  ' "$lab"; fi
  done
  printf '\033[K\n'
  printf '\033[K\n'

  printf '   %sdevices%s  (space toggles, a all, n none)\033[K\n' "$c_cyn" "$c_reset"
  for ((i = 0; i < n; i++)); do
    short="${DEVICES[$i]%%|*}"; short="${short#lineage_}"
    row="$(tui_mark $((i + 1)))"
    (( TUI_SEL[i] )) && row+="[x] " || row+="[ ] "
    (( TUI_FOCUS == i + 1 )) && row+="${c_bold}${short}${c_reset}" || row+="$short"
    printf '%s\033[K\n' "$row"
  done
  printf '\033[K\n'

  row="$(tui_mark $((n + 1)))"
  [[ "$TUI_UPLOAD" == "yes" ]] && row+="[x] " || row+="[ ] "
  (( TUI_FOCUS == n + 1 )) && row+="${c_bold}upload to Buzzheavier${c_reset}" || row+="upload to Buzzheavier"
  printf '%s\033[K\n' "$row"

  row="$(tui_mark $((n + 2)))"
  [[ "$TUI_XGSI" == "yes" ]] && row+="[x] " || row+="[ ] "
  (( TUI_FOCUS == n + 2 )) && row+="${c_bold}xgsi boot/dmesg logs${c_reset}" || row+="xgsi boot/dmesg logs"
  printf '%s\033[K\n' "$row"

  row="$(tui_mark $((n + 3)))"
  row+="gms  "
  (( TUI_FOCUS == n + 3 )) && row+="${c_bold}< ${TUI_GMS_LABELS[$TUI_GMS]} >${c_reset}" || row+="< ${TUI_GMS_LABELS[$TUI_GMS]} >"
  printf '%s\033[K\n' "$row"
  printf '\033[K\n'

  printf '   %sup/down%s move   %sspace%s toggle   %sleft/right%s variant/gms   %sa%s all   %sn%s none\033[K\n' \
    "$c_cyn" "$c_reset" "$c_cyn" "$c_reset" "$c_cyn" "$c_reset" "$c_cyn" "$c_reset" "$c_cyn" "$c_reset"
  printf '   %sx%s xgsi   %sg%s gms   %senter%s start   %sq%s quit\033[K\n' \
    "$c_cyn" "$c_reset" "$c_cyn" "$c_reset" "$c_cyn" "$c_reset" "$c_cyn" "$c_reset"
  [[ -n "$TUI_STATUS" ]] && printf '   %s%s%s\033[K\n' "$c_yel" "$TUI_STATUS" "$c_reset" || printf '\033[K\n'
  printf '\033[J'
}

tui_run() {
  local n=${#DEVICES[@]} i key short req="" all=1 any
  TUI_FOCUS=0; TUI_STATUS=""; TUI_UPLOAD="yes"; TUI_GMS=0
  TUI_SEL=()
  for ((i = 0; i < n; i++)); do TUI_SEL[i]=1; done
  [[ -n "${VARIANT:-}" ]] && TUI_VARIANT="$VARIANT"
  [[ -n "${WITH_XGSI_LOGS:-}" ]] && TUI_XGSI="yes" || TUI_XGSI="no"

  TUI_STTY="$(stty -g </dev/tty 2>/dev/null)"
  stty -echo -icanon min 1 time 0 </dev/tty 2>/dev/null
  trap 'tui_cleanup; exit 130' INT TERM
  printf '\033[2J\033[?25l'
  tui_render

  while :; do
    key="$(tui_key)" || { tui_cleanup; die "no input"; }
    TUI_STATUS=""
    case "$key" in
      up)   (( TUI_FOCUS > 0 )) && TUI_FOCUS=$((TUI_FOCUS - 1)) ;;
      down) (( TUI_FOCUS < n + 3 )) && TUI_FOCUS=$((TUI_FOCUS + 1)) ;;
      left|right)
        if   (( TUI_FOCUS == 0 ));     then [[ "$key" == left ]] && tui_cycle -1 || tui_cycle 1
        elif (( TUI_FOCUS == n + 3 )); then
          if [[ "$key" == left ]]; then TUI_GMS=$(((TUI_GMS + ${#TUI_GMS_MODES[@]} - 1) % ${#TUI_GMS_MODES[@]}))
          else TUI_GMS=$(((TUI_GMS + 1) % ${#TUI_GMS_MODES[@]})); fi
        fi ;;
      space)
        if   (( TUI_FOCUS == 0 ));     then tui_cycle 1
        elif (( TUI_FOCUS == n + 1 )); then [[ "$TUI_UPLOAD" == yes ]] && TUI_UPLOAD="no" || TUI_UPLOAD="yes"
        elif (( TUI_FOCUS == n + 2 )); then [[ "$TUI_XGSI" == yes ]] && TUI_XGSI="no" || TUI_XGSI="yes"
        elif (( TUI_FOCUS == n + 3 )); then TUI_GMS=$(((TUI_GMS + 1) % ${#TUI_GMS_MODES[@]}))
        else TUI_SEL[TUI_FOCUS - 1]=$((1 - TUI_SEL[TUI_FOCUS - 1]))
        fi ;;
      upload) [[ "$TUI_UPLOAD" == yes ]] && TUI_UPLOAD="no" || TUI_UPLOAD="yes" ;;
      xgsi)   [[ "$TUI_XGSI" == yes ]] && TUI_XGSI="no" || TUI_XGSI="yes" ;;
      gms)    TUI_GMS=$(((TUI_GMS + 1) % ${#TUI_GMS_MODES[@]})) ;;
      all)  for ((i = 0; i < n; i++)); do TUI_SEL[i]=1; done ;;
      none) for ((i = 0; i < n; i++)); do TUI_SEL[i]=0; done ;;
      enter)
        any=0
        for ((i = 0; i < n; i++)); do (( TUI_SEL[i] )) && any=1; done
        if (( any == 0 )); then TUI_STATUS="select at least one device"; tui_render; continue; fi
        break ;;
      quit) tui_cleanup; say ""; die "build cancelled" ;;
      *) : ;;
    esac
    tui_render
  done

  for ((i = 0; i < n; i++)); do
    short="${DEVICES[$i]%%|*}"; short="${short#lineage_}"
    (( TUI_SEL[i] )) && req+="${req:+,}$short" || all=0
  done
  tui_cleanup
  printf '\033[2J\033[H'
  VARIANT="$TUI_VARIANT"
  DO_UPLOAD="$TUI_UPLOAD"
  [[ "$TUI_XGSI" == "yes" ]] && WITH_XGSI_LOGS="true" || WITH_XGSI_LOGS=""
  GMS_WANT=("${TUI_GMS_MODES[$TUI_GMS]}")
  [[ "$all" == 1 ]] && REQUESTED="all" || REQUESTED="$req"
}

# plain ask() flow, used when there is no terminal to draw on
menu_ask() {
  local v i short xd

  say ""
  info "build variant"
  select v in user userdebug eng; do
    [[ -n "${v:-}" ]] && break
    warn "pick 1, 2 or 3"
  done
  VARIANT="$v"

  say ""
  info "devices"
  say "  1) all  (X6531 X6531B X6532 KL5 KL5n)"
  say "  2) pick"
  if [[ "$(ask "choice" "1")" == "2" ]]; then
    for ((i = 0; i < ${#DEVICES[@]}; i++)); do
      short="${DEVICES[$i]%%|*}"; short="${short#lineage_}"
      say "  $((i + 1))) $short"
    done
    REQUESTED="$(ask "numbers, comma separated" "1,2,3,4,5")"
  fi

  [[ "$(ask "upload to Buzzheavier?" "y")" =~ ^[Yy] ]] && DO_UPLOAD="yes" || DO_UPLOAD="no"

  say ""
  info "gms modes"
  select gm in "vanilla only" "vanilla + gapps" "vanilla + microG" "all 3 (vanilla + gapps + microG)"; do
    [[ -n "${gm:-}" ]] && break
    warn "pick 1, 2, 3 or 4"
  done
  case "$gm" in
    "vanilla + gapps")  GMS_WANT=(vanilla,gapps) ;;
    "vanilla + microG") GMS_WANT=(vanilla,microg) ;;
    "all 3 (vanilla + gapps + microG)") GMS_WANT=(all) ;;
    *)                  GMS_WANT=(vanilla) ;;
  esac

  [[ -n "$WITH_XGSI_LOGS" ]] && xd="y" || xd="n"
  [[ "$(ask "xgsi boot/dmesg logs?" "$xd")" =~ ^[Yy] ]] && WITH_XGSI_LOGS="true" || WITH_XGSI_LOGS=""
}

interactive_menu() {
  [[ -t 0 && -r /dev/tty ]] && tui_run || menu_ask
  if [[ "$DO_UPLOAD" == "yes" && -z "$BUZZ_ACCOUNT_ID" ]]; then
    BUZZ_ACCOUNT_ID="$(ask "Buzzheavier account id (blank = anonymous)" "")"
  fi
  say ""
}

# ------------------------------------------------------------------ main -----

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--variant)   VARIANT="${2:-}"; shift 2 ;;
      --release)      LUNCH_RELEASE="${2:-}"; shift 2 ;;
      -d|--devices)   REQUESTED="${2:-}"; shift 2 ;;
      -u|--upload)
        DO_UPLOAD="yes"; shift
        if [[ "${1:-}" == "yes" || "${1:-}" == "no" ]]; then DO_UPLOAD="$1"; shift; fi
        ;;
      --no-upload)    DO_UPLOAD="no"; shift ;;
      -a|--account)   BUZZ_ACCOUNT_ID="${2:-}"; shift 2 ;;
      --folder)       BUZZ_FOLDER_ID="${2:-}"; shift 2 ;;
      --no-note)      DO_NOTE="no"; shift ;;
      --jobs)         JOBS="${2:-}"; shift 2 ;;
      --ccache)       CCACHE_SIZE="${2:-}"; shift 2 ;;
      --no-build)     NO_BUILD="yes"; shift ;;
      --notify)       parse_notify "${2:-}"; shift 2 ;;
      --telegram)     parse_notify "telegram:${2:-}"; shift 2 ;;
      --min-free)     MIN_FREE_GB="${2:-}"; shift 2 ;;
      --gms)          GMS_WANT+=("${2:-}"); shift 2 ;;
      --gapps)        GMS_WANT+=(gapps); shift ;;
      --microg)       GMS_WANT+=(microg); shift ;;
      --keep-going)   KEEP_GOING="yes"; shift ;;
      --dry-run)      DRY_RUN="yes"; shift ;;
      --check-only)   CHECK_ONLY="yes"; shift ;;
      -h|--help)      usage; exit 0 ;;
      *) die "unknown option: $1 (try --help)" ;;
    esac
  done
}

find_root() {
  if [[ -n "$ANDROID_ROOT" ]]; then
    [[ -f "$ANDROID_ROOT/build/envsetup.sh" ]] || die "ANDROID_ROOT=$ANDROID_ROOT has no build/envsetup.sh"
    return
  fi
  local d="$PWD"
  local i
  for i in 1 2 3 4 5 6 7 8; do
    if [[ -f "$d/build/envsetup.sh" ]]; then ANDROID_ROOT="$d"; return; fi
    d="$(dirname "$d")"
  done
  die "no AOSP root found - run from the source tree or set ANDROID_ROOT"
}

select_devices() {
  local req="${1// /}"
  local i short w
  local -a want
  SELECTED=()

  if [[ -z "$req" || "$req" == "all" ]]; then
    SELECTED=("${DEVICES[@]}")
    return
  fi
  IFS=',' read -r -a want <<<"$req"
  for w in "${want[@]}"; do
    [[ -n "$w" ]] || continue
    for i in "${!DEVICES[@]}"; do
      short="${DEVICES[$i]%%|*}"; short="${short#lineage_}"
      if [[ "$w" == "$short" || "$w" == "$((i + 1))" ]]; then
        SELECTED+=("${DEVICES[$i]}")
      fi
    done
  done
  [[ ${#SELECTED[@]} -gt 0 ]] || die "no devices matched '$req'"
}

on_interrupt() {
  local r="${ANDROID_ROOT:-}" a
  trap - INT TERM
  say ""
  warn "interrupted - stopping"
  if [[ ${#BUILT[@]} -gt 0 ]]; then
    info "artifacts collected before the interrupt:"
    for a in "${BUILT[@]}"; do say "   ${a#$r/}"; done
  else
    say "   no artifacts collected yet"
  fi
  if [[ ${#LINKS[@]} -gt 0 ]]; then
    info "uploads finished before the interrupt:"
    for a in "${LINKS[@]}"; do say "   $a"; done
  fi
  exit 130
}

main() {
  parse_args "$@"
  [[ -z "$NOTIFY_MODE" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] && NOTIFY_MODE="telegram"
  need curl; need sha1sum; need sha256sum; need base64
  find_root
  ensure_microg_namespace

  if [[ -z "$VARIANT" ]]; then
    [[ -t 0 ]] || die "no variant given - use -v user|userdebug|eng"
    interactive_menu
  fi
  case "$VARIANT" in
    user|userdebug|eng) ;;
    *) die "bad variant: $VARIANT (user|userdebug|eng)" ;;
  esac
  [[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] || { warn "--min-free/MIN_FREE_GB is not a number - using 40"; MIN_FREE_GB=40; }

  select_devices "$REQUESTED"

  # fold --gms/env into the fixed vanilla -> gapps -> microg build order.
  [[ ${#GMS_WANT[@]} -gt 0 ]] || GMS_WANT=("$GMS_MODES")
  normalize_gms "${GMS_WANT[@]+"${GMS_WANT[@]}"}"

  RELEASE_ROOT="$ANDROID_ROOT/out/tranG81-releases"
  LOG_DIR="$ANDROID_ROOT/out/tranG81-logs"
  mkdir -p "$RELEASE_ROOT/$VARIANT" "$LOG_DIR"

  setup_ccache

  local first_product="${SELECTED[0]%%|*}"
  LUNCH_RELEASE="$(resolve_release "$first_product")"
  [[ -n "$LUNCH_RELEASE" ]] || die "could not determine a lunch release - pass --release NAME"

  say "======================================================================"
  info "variant  : $VARIANT"
  info "release  : $LUNCH_RELEASE"
  info "root     : $ANDROID_ROOT"
  if [[ "$DO_UPLOAD" == "yes" ]]; then
    info "upload   : yes $([[ -n "$BUZZ_ACCOUNT_ID" ]] && echo "(account)" || echo "(anonymous)")"
  else
    info "upload   : no"
  fi
  [[ "$NO_BUILD" == "yes" ]] && info "build    : skipped (--no-build)"
  [[ -n "$CCACHE_SIZE" ]] && info "ccache   : ${CCACHE_SIZE}"
  [[ -n "$WITH_XGSI_LOGS" ]] && info "xgsi     : boot/dmesg logs on"
  info "gms      : $(printf '%s ' "${GMS_MODE_LIST[@]}")"
  [[ -n "$NOTIFY_MODE" ]] && info "notify   : $NOTIFY_MODE"
  info "devices  : $(for e in "${SELECTED[@]}"; do printf '%s ' "${e%%|*}"; done)"
  info "releases : ${RELEASE_ROOT#$ANDROID_ROOT/}/$VARIANT/<mode>"
  say "======================================================================"

  if [[ "$DRY_RUN" != "yes" && "$CHECK_ONLY" != "yes" && "$NO_BUILD" != "yes" ]]; then
    check_disk || die "not enough free disk space - refusing to build"
  fi

  trap on_interrupt INT TERM
  RUN_START=$(date +%s)

  local entry product devtree vendortree device sysdev radiodir fp nfc log a name rzip
  local idx=0 total=${#SELECTED[@]} t0 dt status mode
  local -a pf

  for mode in "${GMS_MODE_LIST[@]}"; do
  GMS_MODE="$mode"
  RELEASE_MODE_DIR="$RELEASE_ROOT/$VARIANT/$mode"
  mkdir -p "$RELEASE_MODE_DIR"
  say ""
  info "########## GMS mode: $mode  (${#SELECTED[@]} device(s)) ##########"
  idx=0

  for entry in "${SELECTED[@]}"; do
    idx=$((idx + 1))
    IFS='|' read -r product devtree vendortree device sysdev radiodir fp <<<"$entry"
    nfc=0; [[ "$product" == "lineage_KL5n" ]] && nfc=1

    say ""
    info "=== $product  [$idx/$total]  (device=$device system=$sysdev) ==="

    if ! verify_trees "$product" "$devtree" "$vendortree" "$device" "$radiodir"; then
      err "$product: firmware / tree check failed - refusing to build"
      FAILED+=("$product (firmware check)")
      TIMING+=("$product|$GMS_MODE|-|0|firmware")
      [[ "$KEEP_GOING" == "yes" ]] || break 2
      continue
    fi

    check_dirty "$devtree"
    check_dirty "$vendortree"

    if [[ "$CHECK_ONLY" == "yes" ]]; then
      ok "$product: firmware checks passed (--check-only)"
      continue
    fi

    if [[ "$DRY_RUN" == "yes" ]]; then
      if [[ "$NO_BUILD" == "yes" ]]; then
        say "    --no-build: reuse + upload the artifacts in ${RELEASE_ROOT#$ANDROID_ROOT/}/$VARIANT/$GMS_MODE"
      else
        run_build "$product" "$VARIANT" "$nfc" "$devtree" "$LOG_DIR/$product-$VARIANT-$GMS_MODE.log"
      fi
      say "    -> verify rom, collect zip + $EXTRA_IMAGES, upload each"
      continue
    fi

    t0=$(date +%s)
    status=ok

    if [[ "$NO_BUILD" == "yes" ]]; then
      if ! collect_existing "$product" "$VARIANT"; then
        err "$product: nothing to re-upload"
        FAILED+=("$product [$GMS_MODE] (no artifacts)")
        TIMING+=("$product|$GMS_MODE|-|0|collect")
        [[ "$KEEP_GOING" == "yes" ]] || break 2
        continue
      fi
    else
      # dropping to a different GMS mode needs a fresh product configuration
      if ! ensure_gms_out "$device" "$GMS_MODE"; then
        err "$product: could not prepare out/target/product/$device"
        FAILED+=("$product [$GMS_MODE] (out dir)")
        TIMING+=("$product|$GMS_MODE|$(( $(date +%s) - t0 ))|0|out dir failed")
        [[ "$KEEP_GOING" == "yes" ]] || break 2
        continue
      fi

      # drop stale artifacts so collection cannot grab the previous product's output
      rm -f "$ANDROID_ROOT"/out/target/product/"$device"/lineage*.zip
      for a in $EXTRA_IMAGES; do rm -f "$ANDROID_ROOT/out/target/product/$device/$a"; done

      log="$LOG_DIR/$product-$VARIANT-$GMS_MODE.log"
      if ! run_build "$product" "$VARIANT" "$nfc" "$devtree" "$log"; then
        err "$product: build failed - log: ${log#$ANDROID_ROOT/}"
        show_build_errors "$log"
        notify_log "$log" "tranG81 $VARIANT: $product [$GMS_MODE] build failed"
        FAILED+=("$product [$GMS_MODE] (build)")
        TIMING+=("$product|$GMS_MODE|$(( $(date +%s) - t0 ))|0|build failed")
        [[ "$KEEP_GOING" == "yes" ]] || break 2
        continue
      fi
      ok "$product: built"

      if ! verify_rom "$device" "$fp"; then
        err "$product: ROM firmware does not match - NOT uploading"
        FAILED+=("$product [$GMS_MODE] (rom fingerprint)")
        TIMING+=("$product|$GMS_MODE|$(( $(date +%s) - t0 ))|0|rom mismatch")
        [[ "$KEEP_GOING" == "yes" ]] || break 2
        continue
      fi

      # the produced zip must carry this product's own radio images, not a
      # sibling product's that shares the system device / output dir.
      rzip=$(ls -1t "$ANDROID_ROOT/out/target/product/$device"/lineage*.zip 2>/dev/null | head -n1)
      if ! verify_zip_radio "$rzip" "$vendortree" "$radiodir"; then
        err "$product: produced rom carries the wrong radio firmware - NOT uploading"
        FAILED+=("$product [$GMS_MODE] (rom radio mismatch)")
        TIMING+=("$product|$GMS_MODE|$(( $(date +%s) - t0 ))|0|rom radio mismatch")
        [[ "$KEEP_GOING" == "yes" ]] || break 2
        continue
      fi

      if ! collect_artifacts "$device" "$product" "$VARIANT"; then
        err "$product: could not collect the build artifacts"
        FAILED+=("$product [$GMS_MODE] (no artifacts)")
        TIMING+=("$product|$GMS_MODE|$(( $(date +%s) - t0 ))|0|collect failed")
        [[ "$KEEP_GOING" == "yes" ]] || break 2
        continue
      fi
    fi

    for a in "${COLLECTED[@]}"; do
      ok "collected  ${a#$ANDROID_ROOT/}"
      BUILT+=("$a")
    done

    pf=()
    if [[ "$DO_UPLOAD" == "yes" ]]; then
      for a in "${COLLECTED[@]}"; do
        name="$(basename "$a")"
        if bh_upload "$a" "$name" \
             "tranG81 $product $GMS_MODE $VARIANT $sysdev $(date -u +%Y-%m-%dT%H:%MZ)"; then
          pf+=("$name|$LAST_URL|$LAST_SHA256|$LAST_EXPIRY")
        else
          warn "$product: upload failed for $name"
          FAILED+=("$product [$GMS_MODE] ($name)")
          status=failed
          pf+=("$name|||$LAST_EXPIRY")
        fi
      done
    else
      for a in "${COLLECTED[@]}"; do pf+=("$(basename "$a")|||"); done
    fi

    dt=$(( $(date +%s) - t0 ))
    TIMING+=("$product|$GMS_MODE|$dt|${#COLLECTED[@]}|$status")
    add_json_record "$product" "$GMS_MODE" "$sysdev" "$dt" "$status" "${pf[@]+"${pf[@]}"}"

    # human-readable link block for the notify (per product, per file/category)
    if [[ ${#pf[@]} -gt 0 ]]; then
      local blk="$product  [$GMS_MODE]  ($sysdev)  $status" fent fname furl fcat
      for fent in "${pf[@]}"; do
        IFS='|' read -r fname furl _ <<<"$fent"
        fcat=$(link_category "$fname")
        if [[ -n "$furl" ]]; then
          blk+=$'\n'"   [$fcat] $fname"$'\n'"      $furl"
        else
          blk+=$'\n'"   [$fcat] $fname  (no link)"
        fi
      done
      LINK_BLOCKS+=("$blk")
    fi

    if (( total > 1 && idx < total )); then
      local el=$(( $(date +%s) - RUN_START ))
      local eta=$(( el / idx * (total - idx) ))
      info "$product done in $(human_time "$dt")  ($idx/$total, ~$(human_time "$eta") left)"
    fi
  done
  done

  say ""
  say "============================== summary ==============================="
  if [[ ${#TIMING[@]} -gt 0 ]]; then
    info "timing:"
    local p2 m
    for entry in "${TIMING[@]}"; do
      IFS='|' read -r p2 m dt a status <<<"$entry"
      say "   $(printf '%-14s' "$p2") $(printf '%-6s' "$m") $(printf '%9s' "$([[ "$dt" == "-" ]] && echo - || human_time "$dt")")  ${a} file(s)  $status"
    done
  fi

  info "artifacts: ${#BUILT[@]}$([[ "$CHECK_ONLY" == yes || "$DRY_RUN" == yes ]] && echo " (nothing changed)")"
  for a in "${BUILT[@]:-}"; do [[ -n "$a" ]] && say "   ${a#$ANDROID_ROOT/}"; done

  if [[ ${#LINKS[@]} -gt 0 ]]; then
    info "links:"
    for a in "${LINKS[@]}"; do say "   $a"; done
    printf '%s\n' "${LINKS[@]}" > "$RELEASE_ROOT/links-$VARIANT-$(date -u +%Y%m%d-%H%M%S).txt"
  fi

  if [[ ${#REL_JSON[@]} -gt 0 ]]; then
    local jf="$RELEASE_ROOT/releases-$VARIANT.json" first=1 r m gm=""
    for m in "${GMS_MODE_LIST[@]}"; do gm+="${gm:+, }$(json_str "$m")"; done
    {
      printf '{\n'
      printf '  "variant": %s,\n' "$(json_str "$VARIANT")"
      printf '  "gms_modes": [%s],\n' "$gm"
      printf '  "root": %s,\n' "$(json_str "$ANDROID_ROOT")"
      printf '  "generated": %s,\n' "$(json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
      printf '  "devices": [\n'
      for r in "${REL_JSON[@]}"; do
        [[ "$first" == "1" ]] || printf ',\n'
        first=0
        printf '%s' "$r"
      done
      printf '\n  ]\n}\n'
    } > "$jf" && info "manifest: ${jf#$ANDROID_ROOT/}"
  fi

  info "total: $(human_time $(( $(date +%s) - RUN_START )))   uploaded: $UPLOADED"

  if [[ ${#DIRTY[@]} -gt 0 ]]; then
    warn "dirty trees (uncommitted changes): ${DIRTY[*]}"
  fi

  if [[ ${#FAILED[@]} -gt 0 ]]; then
    err "failed: ${#FAILED[@]}"
    for entry in "${FAILED[@]}"; do say "   $entry"; done
    notify "tranG81 $VARIANT: ${#BUILT[@]} artifact(s), ${#FAILED[@]} failure(s) - ${FAILED[*]}"
    notify_links
    exit 1
  fi
  ok "all done"
  notify "tranG81 $VARIANT: done, ${#BUILT[@]} artifact(s), ${#LINKS[@]} link(s), $(human_time $(( $(date +%s) - RUN_START )))"
  notify_links
}

main "$@"
