#!/usr/bin/env bash
#
# tranG81 - build + release every device, then upload the ROM zip plus
# boot.img and vendor_boot.img of each device to Buzzheavier.
#
# Fixed order:  X6531 -> X6531B -> X6532 -> KL5 -> KL5n
# KL5n is last on purpose: its vendorsetup.sh applies the hardware/nxp/nfc
# patches when PATCH_NFC=true, so it must run after the clean builds.
#
# Run it from the root of the LineageOS source tree (the dir holding
# build/envsetup.sh) or point ANDROID_ROOT at it:
#
#     ./build-all.sh                       # interactive menu
#     ./build-all.sh -v userdebug -u yes    # non-interactive
#     ANDROID_ROOT=~/lineage ./build-all.sh
#
# Requires: bash 4+, curl, sha1sum, base64.  chmod +x this file first.
#
set -uo pipefail

# ---------------------------------------------------------------- config -----

BUZZ_UPLOAD_BASE="${BUZZHEAVIER_UPLOAD_BASE:-https://w.buzzheavier.com}"
BUZZ_DOWNLOAD_BASE="${BUZZHEAVIER_DOWNLOAD_BASE:-https://buzzheavier.com}"
BUZZ_ACCOUNT_ID="${BUZZHEAVIER_ACCOUNT_ID:-}"
BUZZ_FOLDER_ID="${BUZZHEAVIER_FOLDER_ID:-}"

MAKE_TARGET="${MAKE_TARGET:-bacon}"
JOBS="${JOBS:-}"
WITH_XGSI_LOGS="${WITH_XGSI_LOGS:-}"

# images collected and uploaded next to the ROM zip (tagged per product);
# set EXTRA_IMAGES= to upload only the zip.
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
ANDROID_ROOT="${ANDROID_ROOT:-}"

RELEASE_ROOT=""
LOG_DIR=""
declare -a BUILT=() FAILED=() LINKS=() SELECTED=() COLLECTED=()

# ------------------------------------------------------------------ utils ----

c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'
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

    ./build-all.sh                        # interactive menu
    ./build-all.sh -v userdebug -u yes     # non-interactive
    ANDROID_ROOT=~/lineage ./build-all.sh

Before every build it sha1-checks each radio (firmware) image the vendor tree
declares for that product, so a wrong or mixed-up firmware is refused.
After every build it uploads the ROM zip plus boot.img and vendor_boot.img.
Requires: bash 4+, curl, sha1sum, base64.  chmod +x this file first.

Options:
  -v, --variant user|userdebug|eng   build variant (default: interactive menu)
  -d, --devices LIST                 all | X6531,X6531B,X6532,KL5,KL5n
  -u, --upload | --no-upload         upload to Buzzheavier (default: --no-upload)
  -a, --account ID                   Buzzheavier account id (else anonymous)
      --folder ID                    upload into this Buzzheavier directory id
      --no-note                      skip the Buzzheavier note
      --jobs N                       make -jN (default: mka default)
      --keep-going                   keep building the rest after a failure
      --dry-run                      print the plan, touch nothing
      --check-only                   run the firmware safety checks and stop
  -h, --help                         this text

Env: ANDROID_ROOT  BUZZHEAVIER_ACCOUNT_ID  BUZZHEAVIER_FOLDER_ID  JOBS
     WITH_XGSI_LOGS=true  MAKE_TARGET  EXTRA_IMAGES (default: boot.img vendor_boot.img)
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# ------------------------------------------------------------ firmware ------

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
  done < <(sed -n "s/.*add-radio-file-sha1-checked,\($radiodir\/[^,]*\),\([0-9a-f]\{40\}\).*/\1 \2/p" "$mkv")

  if [[ "$count" -eq 0 ]]; then
    err "vendor tree declares no '$radiodir/' firmware - wrong tree for this product?"
    return 1
  fi
  [[ "$bad" -eq 0 ]] || return 1
  info "$count radio images verified for $radiodir/"
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

# ----------------------------------------------------------------- upload ----

bh_upload() {
  local file="$1" name="$2" note="${3:-}"
  local url="$BUZZ_UPLOAD_BASE" id body code resp hdr=()

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
    return 0
  fi

  resp=$(curl -sS --retry 3 --retry-delay 2 -o - -w $'\n%{http_code}' \
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
    return 0
  fi

  ok "$BUZZ_DOWNLOAD_BASE/$id"
  LINKS+=("$BUZZ_DOWNLOAD_BASE/$id $name")
}

# ------------------------------------------------------------------ build ----

run_build() {
  local product="$1" variant="$2" nfc="$3" log="$4"

  if [[ "$DRY_RUN" == "yes" ]]; then
    say "    cd $ANDROID_ROOT"
    say "    source build/envsetup.sh   (PATCH_NFC=$([[ "$nfc" == 1 ]] && echo true || echo unset))"
    say "    lunch ${product}-${variant}"
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

  # shellcheck disable=SC1091
  source build/envsetup.sh >/dev/null || return 1
  lunch "${product}-${variant}" || return 1

  local -a mk=(mka "$MAKE_TARGET")
  [[ -n "$JOBS" ]] && mk+=("-j$JOBS")

  say "+ ${mk[*]}   (log: ${log#$ANDROID_ROOT/})"
  "${mk[@]}" 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}

# move the freshly built artifacts out of the shared out dir with unique names.
# Fills COLLECTED (rom zip first, then the boot images). The zip is fatal if
# missing; a missing boot image is only a warning, so the ROM still ships.
collect_artifacts() {
  local device="$1" product="$2" variant="$3"
  local out="$ANDROID_ROOT/out/target/product/$device"
  local tag stem dest zip img name
  COLLECTED=()

  tag="${product#lineage_}"
  mkdir -p "$RELEASE_ROOT/$variant" || return 1

  zip=$(ls -1t "$out"/lineage*.zip 2>/dev/null | head -n1)
  if [[ -z "$zip" || ! -f "$zip" ]]; then
    err "no lineage*.zip under out/target/product/$device"
    return 1
  fi
  stem="$(basename "$zip")"; stem="${stem%.zip}"
  case "$stem" in
    *"$tag"*) dest="$stem.zip" ;;
    *)        dest="${stem}-${tag}.zip" ;;
  esac
  cp -f "$zip" "$RELEASE_ROOT/$variant/$dest" || return 1
  COLLECTED+=("$RELEASE_ROOT/$variant/$dest")

  # boot.img / vendor_boot.img (both products of a shared out dir write the
  # same file name there, so tag every copy with the product).
  for img in $EXTRA_IMAGES; do
    if [[ ! -f "$out/$img" ]]; then
      warn "$img not produced for $product - skipped"
      continue
    fi
    name="${img%.img}-${tag}.img"
    cp -f "$out/$img" "$RELEASE_ROOT/$variant/$name" || return 1
    COLLECTED+=("$RELEASE_ROOT/$variant/$name")
  done
}

# --------------------------------------------------------------- menu ---------

ask() { local p="$1" d="$2" a; read -r -p "$p [$d]: " a </dev/tty; printf '%s' "${a:-$d}"; }

interactive_menu() {
  local v i short

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
    REQUESTED=$(ask "numbers, comma separated" "1,2,3,4,5")
  fi

  if [[ "$(ask "upload to Buzzheavier?" "y")" =~ ^[Yy] ]]; then
    DO_UPLOAD="yes"
    if [[ -z "$BUZZ_ACCOUNT_ID" ]]; then
      BUZZ_ACCOUNT_ID=$(ask "Buzzheavier account id (blank = anonymous)" "")
    fi
  fi
  say ""
}

# ------------------------------------------------------------------ main -----

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--variant)   VARIANT="${2:-}"; shift 2 ;;
      -d|--devices)   REQUESTED="${2:-}"; shift 2 ;;
      -u|--upload)    DO_UPLOAD="yes"; shift ;;
      --no-upload)    DO_UPLOAD="no"; shift ;;
      -a|--account)   BUZZ_ACCOUNT_ID="${2:-}"; shift 2 ;;
      --folder)       BUZZ_FOLDER_ID="${2:-}"; shift 2 ;;
      --no-note)      DO_NOTE="no"; shift ;;
      --jobs)         JOBS="${2:-}"; shift 2 ;;
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

main() {
  parse_args "$@"
  need curl; need sha1sum; need base64
  find_root

  if [[ -z "$VARIANT" ]]; then
    [[ -t 0 ]] || die "no variant given - use -v user|userdebug|eng"
    interactive_menu
  fi
  case "$VARIANT" in
    user|userdebug|eng) ;;
    *) die "bad variant: $VARIANT (user|userdebug|eng)" ;;
  esac

  select_devices "$REQUESTED"

  RELEASE_ROOT="$ANDROID_ROOT/out/tranG81-releases"
  LOG_DIR="$ANDROID_ROOT/out/tranG81-logs"
  mkdir -p "$RELEASE_ROOT/$VARIANT" "$LOG_DIR"

  say "======================================================================"
  info "variant  : $VARIANT"
  info "root     : $ANDROID_ROOT"
  if [[ "$DO_UPLOAD" == "yes" ]]; then
    info "upload   : yes $([[ -n "$BUZZ_ACCOUNT_ID" ]] && echo "(account)" || echo "(anonymous)")"
  else
    info "upload   : no"
  fi
  info "devices  : $(for e in "${SELECTED[@]}"; do printf '%s ' "${e%%|*}"; done)"
  info "releases : ${RELEASE_ROOT#$ANDROID_ROOT/}/$VARIANT"
  say "======================================================================"

  local entry product devtree vendortree device sysdev radiodir fp nfc log zip
  for entry in "${SELECTED[@]}"; do
    IFS='|' read -r product devtree vendortree device sysdev radiodir fp <<<"$entry"
    nfc=0; [[ "$product" == "lineage_KL5n" ]] && nfc=1

    say ""
    info "=== $product  (device=$device system=$sysdev) ==="

    if ! verify_trees "$product" "$devtree" "$vendortree" "$device" "$radiodir"; then
      err "$product: firmware / tree check failed - refusing to build"
      FAILED+=("$product (firmware check)")
      [[ "$KEEP_GOING" == "yes" ]] || break
      continue
    fi

    if [[ "$CHECK_ONLY" == "yes" ]]; then
      ok "$product: firmware checks passed (--check-only)"
      continue
    fi

    if [[ "$DRY_RUN" == "yes" ]]; then
      run_build "$product" "$VARIANT" "$nfc" "$LOG_DIR/$product-$VARIANT.log"
      say "    -> verify rom, collect zip + $EXTRA_IMAGES, upload each"
      continue
    fi

    # drop stale artifacts so collection cannot grab the previous product's output
    rm -f "$ANDROID_ROOT"/out/target/product/"$device"/lineage*.zip
    for img in $EXTRA_IMAGES; do rm -f "$ANDROID_ROOT/out/target/product/$device/$img"; done

    log="$LOG_DIR/$product-$VARIANT.log"
    if ! run_build "$product" "$VARIANT" "$nfc" "$log"; then
      err "$product: build failed - see ${log#$ANDROID_ROOT/}"
      FAILED+=("$product (build)")
      [[ "$KEEP_GOING" == "yes" ]] || break
      continue
    fi
    ok "$product: built"

    if ! verify_rom "$device" "$fp"; then
      err "$product: ROM firmware does not match - NOT uploading"
      FAILED+=("$product (rom fingerprint)")
      [[ "$KEEP_GOING" == "yes" ]] || break
      continue
    fi

    if ! collect_artifacts "$device" "$product" "$VARIANT"; then
      err "$product: could not collect the build artifacts"
      FAILED+=("$product (no artifacts)")
      [[ "$KEEP_GOING" == "yes" ]] || break
      continue
    fi
    local a
    for a in "${COLLECTED[@]}"; do
      ok "collected  ${a#$ANDROID_ROOT/}"
      BUILT+=("$a")
    done

    if [[ "$DO_UPLOAD" == "yes" ]]; then
      for a in "${COLLECTED[@]}"; do
        if ! bh_upload "$a" "$(basename "$a")" \
             "tranG81 $product $VARIANT $sysdev $(date -u +%Y-%m-%dT%H:%MZ)"; then
          warn "$product: upload failed for $(basename "$a")"
          FAILED+=("$product ($(basename "$a"))")
        fi
      done
    fi
  done

  say ""
  say "============================== summary ==============================="
  info "artifacts: ${#BUILT[@]}$([[ "$CHECK_ONLY" == yes || "$DRY_RUN" == yes ]] && echo " (nothing changed)")"
  for zip in "${BUILT[@]:-}"; do [[ -n "$zip" ]] && say "   ${zip#$ANDROID_ROOT/}"; done

  if [[ ${#LINKS[@]} -gt 0 ]]; then
    info "links:"
    for l in "${LINKS[@]}"; do say "   $l"; done
    printf '%s\n' "${LINKS[@]}" > "$RELEASE_ROOT/links-$VARIANT-$(date -u +%Y%m%d-%H%M%S).txt"
  fi

  if [[ ${#FAILED[@]} -gt 0 ]]; then
    err "failed: ${#FAILED[@]}"
    for entry in "${FAILED[@]}"; do say "   $entry"; done
    exit 1
  fi
  ok "all done"
}

main "$@"
