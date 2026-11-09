#!/usr/bin/env bash
#
# tranG81 - build + release every device, then upload the ROM zip plus
# boot.img and vendor_boot.img of each device to Buzzheavier.  The same files
# can also be mirrored to GitHub Releases and SourceForge (--gh / --sf), or a
# past Buzzheavier link published on its own (--mirror).
#
# The ROM is chosen with --rom (default lineage); a profile supplies the
# product prefix, artifact name, supported GMS modes and who provides the
# GApps/microG payload.  LineageOS uses our own device.mk gate (vendor/gapps,
# vendor/partner_gms); other ROMs keep their own GApps/microG integration and
# the script only flips their switch.
#
# Fixed order:  X6531 -> X6531B -> X6532 -> KL5 -> KL5n; each device builds all
# its GMS modes before the next device starts.  KL5n is last on purpose: its
# vendorsetup.sh applies the hardware/nxp/nfc patches when PATCH_NFC=true and
# never reverts them, so it must run after every other device.
#
# Every selected device is built once per GMS mode, in the fixed order
# vanilla -> gapps -> microg (microG always last): the mode selects a payload
# (vendor/gapps or vendor/partner_gms), never both.
#
# Run it from the root of the ROM source tree (the dir holding
# build/envsetup.sh) or point ANDROID_ROOT at it:
#
#     ./build-all.sh                       # interactive TUI menu
#     ./build-all.sh --rom yaap -v userdebug -u yes
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

# extra release mirrors, off by default (Buzzheavier stays on -u):
#   GitHub Releases - one release per codename, tag/name = the codename
#     (X6531 .. KL5n).  Every asset of that codename is replaced each run, so a
#     ROM rebuilt across ROMs/GMS modes accumulates in the same release.  gh
#     CLI auth (GH_TOKEN/GITHUB_TOKEN or a stored login); no gh, no release.
#   SourceForge - rsync over your SSH key (BatchMode) into the FRS project tree,
#     /home/frs/project/<project>/<folder>/<codename>/; the folder is asked once
#     (list, pick or create) and kept in SF_FOLDER.
GH_RELEASE_REPO="${GH_RELEASE_REPO:-Transsion-G81/releases}"
SF_USER="${SF_USER:-opekfurina}"
SF_PROJECT="${SF_PROJECT:-transsion-g81}"
SF_HOST="${SF_HOST:-frs.sourceforge.net}"
SF_FOLDER="${SF_FOLDER:-}"
DO_GH="no"
DO_SF="no"

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

# Extra make lines appended to the very bottom of the product makefile
# (device/<devtree>/<product>.mk) just before lunch and taken off again after
# the build, so the shared tree stays clean and ROM-neutral.  PRODUCT_EXTRA_LINES
# applies to every device; PRODUCT_EXTRA_LINES_<device> (X6531, X6531B, X6532,
# KL5, KL5n) overrides it for one.
PRODUCT_EXTRA_LINES="${PRODUCT_EXTRA_LINES:-}"
INJECTED_MK=""

# custom-ROM profile (--rom); rom_load() fills these in and apply_rom() turns
# the device keys above into full product names.  ROM_MODES / ROM_GMS_ENV_* are
# filled by rom_detect_gms(): for LineageOS from our own device gate, for other
# ROMs by probing the synced tree for the GApps/microG it actually ships.
ROM="${ROM:-lineage}"
ROM_NAME=""
ROM_PREFIX=""
ROM_ZIP_GLOB=""
ROM_VENDOR=""
ROM_MODES=""
ROM_GMS_OWNER=""
ROM_GMS_VARS=""
ROM_GMS_ENV_vanilla=""
ROM_GMS_ENV_gapps=""
ROM_GMS_ENV_microg=""
ROM_HAVE_GAPPS="no"
ROM_HAVE_MICROG="no"
ROM_GAPPS_TOGGLE=""
ROM_MICROG_TOGGLE=""
ROM_RELEASE_FILE=""
ROM_RELEASE_CMD=""
ROM_LUNCH_STYLE=""
ROM_SETUP_CMD="lunch"     # the ROM's own "configure a device" command
ROM_BUILD_CMD="mka"       # the ROM's own build command
ROM_BUILD_TYPE=""         # extra build flag (AxionOS: -b bacon)
ROM_GMS_ARG_vanilla=""    # GMS choice passed to ROM_SETUP_CMD (ROM_GMS_OWNER=cmd)
ROM_GMS_ARG_gapps=""
ROM_GMS_ARG_microg=""
ROM_PRODUCT_EXTRA=""

# images collected and uploaded next to the ROM zip (tagged per product);
# set EXTRA_IMAGES= to upload only the zip, add dtbo.img to include it.
EXTRA_IMAGES="${EXTRA_IMAGES-boot.img vendor_boot.img}"

# name | device tree | vendor tree | PRODUCT_DEVICE | PRODUCT_SYSTEM_DEVICE | radio dir | stock fingerprint
# (the product name is "<rom prefix><key>", e.g. lineage_X6532 - see apply_rom)
DEVICES=(
  "X6531|device/infinix/X6531|vendor/infinix/X6531|X6531|X6531|radio|Infinix/X6531-OP/Infinix-X6531:14/UP1A.231005.007/240820V1958:user/release-keys"
  "X6531B|device/infinix/X6531|vendor/infinix/X6531|X6531|X6531B|radio_x6531b|Infinix/X6531B-OP/Infinix-X6531B:14/UP1A.231005.007/260713V1136:user/release-keys"
  "X6532|device/infinix/X6532|vendor/infinix/X6532|X6532|X6532|radio|Infinix/X6532-OP/Infinix-X6532:14/UP1A.231005.007/240820V2071:user/release-keys"
  "KL5|device/tecno/KL5|vendor/tecno/KL5|KL5|KL5|radio|TECNO/KL5-OP/TECNO-KL5:14/UP1A.231005.007/240811V1304:user/release-keys"
  "KL5n|device/tecno/KL5|vendor/tecno/KL5|KL5|KL5n|radio_kl5n|TECNO/KL5n-OP/TECNO-KL5n:14/UP1A.231005.007/260710V887:user/release-keys"
)
# pristine list: applying a ROM prefixes DEVICES, so the TUI's ROM row needs the
# unprefixed list to switch profiles without stacking prefixes.
BASE_DEVICES=("${DEVICES[@]}")

VARIANT=""
REQUESTED="all"
DO_UPLOAD="no"
DO_NOTE="yes"
KEEP_GOING="no"
DRY_RUN="no"
CHECK_ONLY="no"
NO_BUILD="no"
REVERT_PATCHES="no"
NOTIFY_URL=""
ANDROID_ROOT="${ANDROID_ROOT:-}"

# LineageOS 23.x lunch() needs <product> <release> <variant>; the release (e.g.
# bp4a) is not optional.  Empty = auto-detect from the ROM's own release pin
# file.  Only --release / LUNCH_RELEASE override it: never an ambient
# TARGET_RELEASE, which a previous `lunch` in the same shell leaves exported
# and which silently fed one ROM's release to the next ROM's lunch.
LUNCH_RELEASE="${LUNCH_RELEASE:-}"

RELEASE_ROOT=""
LOG_DIR=""
declare -a BUILT=() FAILED=() LINKS=() SELECTED=() COLLECTED=()
declare -a TIMING=() DIRTY=() REL_JSON=() LINK_BLOCKS=()
declare -a GMS_WANT=() GMS_MODE_LIST=()
declare -a MIRROR_URLS=() MIRROR_LINKS=()
declare -A GH_MIRRORED=()
GMS_MODE="" RELEASE_MODE_DIR=""

# filled in by bh_upload() for the caller
LAST_URL="" LAST_SHA256="" LAST_EXPIRY="" UPLOADED=0 EXPIRY_WARNED="no"
# release-mirror counters and the --mirror codename override
GH_UPLOADED=0 SF_UPLOADED=0 MIRROR_CODENAME=""
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

# ------------------------------------------------------------------- rom -----

# Load the active custom-ROM profile (--rom).  A profile gives the product
# prefix, the artifact name, the ROM's vendor dir and lunch style; the GApps and
# microG modes come from rom_detect_gms(), which reads what the tree ships
# instead of hardcoding per-ROM switch names.
rom_load() {
  # reset the per-ROM entry points so nothing leaks between profiles
  ROM_SETUP_CMD="lunch"; ROM_BUILD_CMD="mka"; ROM_BUILD_TYPE=""
  ROM_GMS_ARG_vanilla=""; ROM_GMS_ARG_gapps=""; ROM_GMS_ARG_microg=""
  ROM_GMS_ENV_vanilla=""; ROM_GMS_ENV_gapps=""; ROM_GMS_ENV_microg=""
  ROM_RELEASE_FILE=""; ROM_RELEASE_CMD=""; ROM_PRODUCT_EXTRA=""
  case "$ROM" in
    lineage)
      ROM_NAME="LineageOS"
      ROM_PREFIX="lineage_"
      # mka bacon on some trees leaves "lineage_<dev>-ota.zip" rather than the
      # release-named "lineage-<ver>-...", so match both spellings
      ROM_ZIP_GLOB="lineage*.zip"
      ROM_VENDOR="vendor/lineage"
      ROM_GMS_OWNER="device"
      ROM_RELEASE_FILE="vendor/lineage/vars/aosp_target_release"
      ROM_RELEASE_CMD="list_releases"
      ROM_LUNCH_STYLE="release"
      ;;
    evox)
      # Evolution X keeps the Lineage tree/vendor, so the product is lineage_*.
      ROM_NAME="Evolution X"
      ROM_PREFIX="lineage_"
      ROM_ZIP_GLOB="EvolutionX-*.zip"
      ROM_VENDOR="vendor/evolution"
      ROM_GMS_OWNER="rom"
      ROM_RELEASE_FILE="vendor/lineage/vars/aosp_target_release"
      ROM_LUNCH_STYLE="release"
      ;;
    yaap)
      ROM_NAME="YAAP"
      ROM_PREFIX="yaap_"
      ROM_ZIP_GLOB="YAAP-*.zip"
      ROM_VENDOR="vendor/yaap"
      ROM_GMS_OWNER="rom"
      ROM_LUNCH_STYLE="flat"
      ;;
    infinity)
      ROM_NAME="Project Infinity X"
      ROM_PREFIX="infinity_"
      ROM_ZIP_GLOB="Project_Infinity-X-*.zip"
      ROM_VENDOR="vendor/infinity"
      ROM_GMS_OWNER="rom"
      ROM_LUNCH_STYLE="flat"
      ;;
    axion)
      # AxionOS keeps the Lineage tree (its own vendor/lineage fork) and its
      # device trees ship lineage_* products, but it is configured and built
      # through its own commands, not lunch/mka:  "axion <codename> <variant>
      # <gms>" then "ax -b" (its README).  The GMS choice is an argument to
      # that command, so rom_detect_gms() reads the passes from ROM_GMS_ARG_*.
      ROM_NAME="AxionOS"
      ROM_PREFIX="lineage_"
      ROM_ZIP_GLOB="axion-*.zip"
      ROM_VENDOR="vendor/lineage"
      ROM_GMS_OWNER="cmd"
      ROM_LUNCH_STYLE="axion"
      ROM_SETUP_CMD="axion"
      ROM_BUILD_CMD="ax"
      ROM_BUILD_TYPE="-b"                 # bacon -> the flashable zip
      ROM_GMS_ARG_vanilla="vanilla"
      ROM_GMS_ARG_gapps="gms"             # axion's full-GMS arg
      # Axion has no microG flavor of its own, so a microG pass configures the
      # vanilla variant and turns on the gate our device tree reads; unsupported
      # upstream, so it may not build or boot.
      ROM_GMS_ARG_microg="vanilla"
      ROM_GMS_ENV_microg="WITH_MICROG=true"
      # Axion's common mk turns on package-existence enforcement, which its
      # README tells device trees to opt out of; inject it so our Lineage-based
      # tree does not have to carry an Axion-only line.
      ROM_PRODUCT_EXTRA="TARGET_DISABLE_EPPE := true"
      ;;
    *) die "unknown ROM '$ROM' (known: lineage evox yaap infinity axion)" ;;
  esac
  ROM_GMS_ENV_vanilla="${ROM_GMS_ENV_vanilla:-}"
}

# Decide which GMS passes make sense and how to turn each on.  LineageOS uses the
# gate our device.mk reads; every other ROM is probed: if it ships a Gapps tree
# (or exposes a switch for one) it gets a gapps pass, likewise microG.  The
# switch name is taken from the ROM's own config so nothing is hardcoded.
rom_detect_gms() {
  ROM_MODES=""; ROM_GMS_VARS=""
  ROM_HAVE_GAPPS="no"; ROM_HAVE_MICROG="no"
  ROM_GAPPS_TOGGLE=""; ROM_MICROG_TOGGLE=""

  if [[ "$ROM_GMS_OWNER" == device ]]; then
    ROM_MODES="vanilla gapps microg"
    ROM_GMS_VARS="WITH_GAPPS WITH_MICROG"
    ROM_GMS_ENV_gapps="WITH_GAPPS=true"
    ROM_GMS_ENV_microg="WITH_MICROG=true"
    return 0
  fi

  if [[ "$ROM_GMS_OWNER" == cmd ]]; then
    # the ROM's own configure command takes the GMS choice as an argument, so
    # offer the passes its profile knows an argument for (AxionOS: vanilla/gms)
    ROM_MODES="vanilla"
    [[ -n "$ROM_GMS_ARG_gapps" ]] && ROM_MODES+=" gapps"
    [[ -n "$ROM_GMS_ARG_microg" ]] && ROM_MODES+=" microg"
    # remember every switch the profile exports so a pass that does not want one
    # unsets it again (set_gms_env)
    local e
    for e in $(rom_gms_env vanilla) $(rom_gms_env gapps) $(rom_gms_env microg); do
      [[ -n "$e" ]] && ROM_GMS_VARS="${ROM_GMS_VARS:+$ROM_GMS_VARS }${e%%=*}"
    done
    return 0
  fi

  local base="$ANDROID_ROOT/${ROM_VENDOR}" d v
  for d in vendor/gms vendor/google/gms vendor/gapps; do
    [[ -e "$ANDROID_ROOT/$d" ]] && ROM_HAVE_GAPPS=yes
  done
  for d in vendor/microg vendor/microG; do
    [[ -e "$ANDROID_ROOT/$d" ]] && ROM_HAVE_MICROG=yes
  done

  if [[ -d "$base" ]]; then
    for v in WITH_GMS WITH_GAPPS TARGET_BUILD_GAPPS TARGET_INCLUDE_GAPPS TARGET_SUPPORTS_GOOGLE_APPS; do
      if grep -rqsE "(^|[^A-Za-z0-9_])$v([^A-Za-z0-9_]|$)" "$base" --include='*.mk' 2>/dev/null; then
        ROM_HAVE_GAPPS=yes; ROM_GAPPS_TOGGLE="$v"; break
      fi
    done
    for v in WITH_MICROG TARGET_BUILD_MICROG INCLUDE_MICROG TARGET_SUPPORTS_MICROG; do
      if grep -rqsE "(^|[^A-Za-z0-9_])$v([^A-Za-z0-9_]|$)" "$base" --include='*.mk' 2>/dev/null; then
        ROM_HAVE_MICROG=yes; ROM_MICROG_TOGGLE="$v"; break
      fi
    done
  fi

  ROM_MODES="vanilla"
  ROM_GMS_ENV_vanilla=""; ROM_GMS_ENV_gapps=""; ROM_GMS_ENV_microg=""
  if [[ "$ROM_HAVE_GAPPS" == yes ]]; then
    ROM_MODES+=" gapps"
    [[ -n "$ROM_GAPPS_TOGGLE" ]] && ROM_GMS_ENV_gapps="$ROM_GAPPS_TOGGLE=true"
    # if the ROM turns GApps on by default, the vanilla pass must turn them off
    if [[ -n "$ROM_GAPPS_TOGGLE" ]] && \
       grep -rqsE "^[[:space:]]*$ROM_GAPPS_TOGGLE[[:space:]]*[?:]?=[[:space:]]*true" "$base" --include='*.mk' 2>/dev/null; then
      ROM_GMS_ENV_vanilla="$ROM_GAPPS_TOGGLE=false"
    fi
  fi
  if [[ "$ROM_HAVE_MICROG" == yes ]]; then
    ROM_MODES+=" microg"
    [[ -n "$ROM_MICROG_TOGGLE" ]] && ROM_GMS_ENV_microg="$ROM_MICROG_TOGGLE=true"
  fi
  [[ -n "$ROM_GAPPS_TOGGLE" ]] && ROM_GMS_VARS="${ROM_GMS_VARS:+$ROM_GMS_VARS }$ROM_GAPPS_TOGGLE"
  [[ -n "$ROM_MICROG_TOGGLE" ]] && ROM_GMS_VARS="${ROM_GMS_VARS:+$ROM_GMS_VARS }$ROM_MICROG_TOGGLE"
  return 0
}

# the env assignment exported for a GMS pass (empty for vanilla)
rom_gms_env() {
  local n="ROM_GMS_ENV_$1"
  printf '%s' "${!n:-}"
}

# the GMS value the ROM's own configure command wants for a mode; empty when
# the ROM reads its GMS choice from the environment instead (AxionOS: "gms").
rom_gms_arg() {
  local n="ROM_GMS_ARG_$1"
  printf '%s' "${!n:-}"
}

# how to build: the command and flags for the active ROM, one word per line.
# mka takes the make target; AxionOS's ax takes a build-type flag instead.
rom_build_args() {
  printf '%s\n' "$ROM_BUILD_CMD"
  case "$ROM_BUILD_CMD" in
    make|mka) printf '%s\n' "$MAKE_TARGET" ;;
  esac
  [[ -n "$ROM_BUILD_TYPE" ]] && printf '%s\n' "$ROM_BUILD_TYPE"
  [[ -n "$JOBS" ]] && printf '%s\n' "-j$JOBS"
  return 0
}

# the arguments the ROM's configure command takes for <product> <variant>:
# lineage wants a release config, AxionOS's axion wants <codename> <variant>
# <gms>, the rest just take the product.
rom_setup_args() {
  case "$ROM_LUNCH_STYLE" in
    release) printf '%s %s %s' "$1" "$LUNCH_RELEASE" "$2" ;;
    dash)    printf '%s-%s' "$1" "$2" ;;
    axion)   printf '%s %s %s' "${1#$ROM_PREFIX}" "$2" "$(rom_gms_arg "$GMS_MODE")" ;;
    *)       printf '%s %s' "$1" "$2" ;;
  esac
}

# prefix every device key with the product prefix (X6532 -> lineage_X6532)
apply_rom() {
  rom_load
  local -a out=(); local e
  for e in "${DEVICES[@]}"; do out+=("${ROM_PREFIX}${e}"); done
  DEVICES=("${out[@]}")
}

# the GMS menu options this ROM supports: each pass on its own, then the combos
# (vanilla is always offered).  A combo shows only for the passes the ROM ships.
rom_gms_menu() {
  local has_gapps=0 has_microg=0
  [[ " $ROM_MODES " == *" gapps "* ]] && has_gapps=1
  [[ " $ROM_MODES " == *" microg "* ]] && has_microg=1

  MENU_GMS_OPTS=(vanilla); MENU_GMS_WANTS=(vanilla)
  TUI_GMS_MODES=(vanilla);  TUI_GMS_LABELS=(vanilla)
  if (( has_gapps )); then
    MENU_GMS_OPTS+=("gapps only");      MENU_GMS_WANTS+=("gapps")
    TUI_GMS_MODES+=("gapps");           TUI_GMS_LABELS+=("gapps")
  fi
  if (( has_microg )); then
    MENU_GMS_OPTS+=("microG only");     MENU_GMS_WANTS+=("microg")
    TUI_GMS_MODES+=("microg");          TUI_GMS_LABELS+=("microg")
  fi
  if (( has_gapps )); then
    MENU_GMS_OPTS+=("vanilla + gapps"); MENU_GMS_WANTS+=("vanilla,gapps")
    TUI_GMS_MODES+=("vanilla,gapps");   TUI_GMS_LABELS+=("vanilla+gapps")
  fi
  if (( has_gapps && has_microg )); then
    MENU_GMS_OPTS+=("all 3 (vanilla + gapps + microG)"); MENU_GMS_WANTS+=(all)
    TUI_GMS_MODES+=("vanilla,gapps,microg");             TUI_GMS_LABELS+=("all")
  fi
}

# the ROM list the TUI / plain menu offers, in profile order
ROMS=(lineage evox yaap infinity axion)

# everything the build needs from the active profile: the GMS passes the tree
# offers, its menu, and the microG tree prep.
rom_prepare() {
  rom_detect_gms
  # prep the microG tree whenever a microG pass is on offer (Lineage's device
  # gate, or a ROM whose profile adds one); both steps no-op without the tree.
  if [[ " $ROM_MODES " == *" microg "* ]]; then
    ensure_microg_namespace
    prune_microg_unshipped
  fi
  rom_gms_menu
}

# switch the active ROM profile from the pristine device list; used by the TUI's
# ROM row and the plain fallback menu.
set_rom() {
  ROM="$1"
  DEVICES=("${BASE_DEVICES[@]}")
  apply_rom
  rom_prepare
}

usage() {
  cat <<'EOF'
tranG81 - build + release every device, then upload each ROM to Buzzheavier.

Fixed order:  X6531 -> X6531B -> X6532 -> KL5 -> KL5n, all GMS modes of a
device before the next.  KL5n is last on purpose: its vendorsetup.sh applies
the hardware/nxp/nfc patches when PATCH_NFC=true and never reverts them, so it
runs after every other device.

Run it from the root of the ROM source tree (the dir holding build/envsetup.sh)
or point ANDROID_ROOT at it.  The ROM is chosen with --rom (default lineage):

    ./build-all.sh                        # interactive TUI menu
    ./build-all.sh --rom yaap -v userdebug -u yes
    ANDROID_ROOT=~/lineage ./build-all.sh

The menu is a pure-bash full-screen TUI (arrow keys, checkboxes, colours) -
dialog, whiptail and fzf are not used and nothing has to be installed.  Piping
stdin or running without a terminal falls back to plain numbered prompts.  The
"rom" row selects the ROM profile (default lineage, same as --rom) and reloads
that profile's devices and GMS menu, so e.g. AxionOS can be built from the menu
alone; the "make lines" row edits the lines a ROM profile appends to the product
makefile (bottom of the file, for the build only - see PRODUCT_EXTRA_LINES
below); the "r" key reverse-applies the patches our device trees drop into the
source and stops (same as --revert-patches).

Every ROM is configured and built through its own entry points, taken from its
profile: lineage, evox, yaap and infinity use lunch + mka, AxionOS uses its own
"axion <codename> <variant> <gms>" then "ax -b".  AxionOS's GMS choice rides on
that command (gms arg = vanilla|gms), and the build loop hardcodes none of it.

Before every build it sha1-checks each radio (firmware) image the vendor tree
declares for that product, so a wrong or mixed-up firmware is refused.  After
every build it re-checks that the produced ROM zip carries that product's own
radio images (by content sha1), then collects the ROM zip plus
boot.img/vendor_boot.img (put more in EXTRA_IMAGES, e.g. dtbo.img) and uploads
them; each upload is sha256-verified against the hash the service reports, and
the expiry is printed (anonymous links expire in a few days).  With Telegram
notify, a second message lists the download link of every uploaded file,
grouped per device and tagged rom / boot / vendor_boot / image.
Requires: bash 4+, curl, sha1sum, sha256sum, base64.  Optional: gh (GitHub
releases) and ssh + rsync (SourceForge).  chmod +x this file first.

Release mirrors (-u stays Buzzheavier):
  --gh publishes each codename to one GitHub release (tag and name = the
  codename, e.g. X6532; its assets - rom zip, boot-<dev>.img,
  vendor_boot-<dev>.img and EXTRA_IMAGES - are replaced on every run, so a
  rebuild across ROMs/GMS modes lands in the same release).  gh authenticates
  itself from GH_TOKEN / GITHUB_TOKEN or a stored login; with no gh, GitHub is
  skipped with a warning.
  --sf rsyncs the same files over your SSH key to
  frs.sourceforge.net:/home/frs/project/<SF_PROJECT>/<SF_FOLDER>/<codename>/.
  The folder (SF_FOLDER) is chosen once from the project's folders or created
  new; ssh runs in BatchMode, so a missing key fails fast instead of prompting.
  --mirror skips the build: it downloads the given links (e.g. a past Buzzheavier
  upload), works out each file's codename from its name (--codename overrides)
  and publishes them to the enabled mirrors, then exits.

Options:
      --rom NAME                     ROM profile: lineage, evox (Evolution X),
                                     yaap, infinity (Project Infinity X),
                                     axion (default: lineage)
  -v, --variant user|userdebug|eng   build variant (default: interactive TUI)
      --release NAME                 lunch release config (e.g. bp4a); default
                                     reads the ROM's release pin (if it has one)
  -d, --devices LIST                 all | X6531,X6531B,X6532,KL5,KL5n
  -u, --upload | --no-upload         upload to Buzzheavier (default: --no-upload)
  -a, --account ID                   Buzzheavier account id (else anonymous)
      --folder ID                    upload into this Buzzheavier directory id
      --no-note                      skip the Buzzheavier note
      --gh [yes|no]                  also publish to GitHub Releases
                                     (GH_RELEASE_REPO, one release per codename,
                                     assets replaced each run); default no
      --no-gh                        do not publish to GitHub
      --sf [yes|no]                  also publish to SourceForge under the FRS
                                     project (ssh+rsync); default no
      --no-sf                        do not publish to SourceForge
      --gh-repo OWNER/REPO           GitHub release repo
                                     (default Transsion-G81/releases)
      --sf-folder NAME               SourceForge folder under the project; else
                                     the menu lists them and asks (file-manager
                                     style, "n" creates a new one)
      --mirror URL[,URL...]          no build: fetch these links and publish them
                                     to the enabled mirrors
      --codename NAME                codename for --mirror files (else it is read
                                     from the file's own name)
      --jobs N                       parallel jobs for the ROM's build
                                     (default: mka/ax default)
      --ccache SIZE                  enable ccache and cap it at SIZE (e.g. 50G)
      --no-build                     skip building; re-upload collected artifacts
      --notify TARGET                status ping: a Discord/Slack webhook URL,
                                     telegram:TOKEN:CHAT, or a Telegram bot URL
      --telegram TOKEN:CHAT          shorthand for --notify telegram:TOKEN:CHAT
      --min-free GB                  refuse to start below this free space (default 40)
      --keep-going                   keep building the rest after a failure
      --dry-run                      print the plan, touch nothing
      --check-only                   run the firmware safety checks and stop
      --revert-patches               reverse-apply the patches our device trees
                                     drop into the source (SystemUI, NFC HAL)
                                     for the selected devices, then stop
      --gms MODES                    GMS passes per device: vanilla (default),
                                     gapps, microg (each builds only that pass),
                                     vanilla+gapps, or all (= the three passes).
                                     Built in the fixed order vanilla -> gapps ->
                                     microg; microG is always last.
      --gapps                        shorthand for --gms gapps
      --microg                       shorthand for --gms microg
  -h, --help                         this text

Env: ANDROID_ROOT  BUZZHEAVIER_ACCOUNT_ID  BUZZHEAVIER_FOLDER_ID  JOBS  CCACHE_SIZE
     MIN_FREE_GB (default 40)  WITH_XGSI_LOGS  GMS_MODES  MAKE_TARGET (mka ROMs)
     PRODUCT_EXTRA_LINES (make lines appended to the product makefile for the
     build, e.g. "AXION_PROCESSOR := MediaTek_Helio_G81"; PRODUCT_EXTRA_LINES_<device>
     overrides it per device, e.g. PRODUCT_EXTRA_LINES_X6532)
     TELEGRAM_BOT_TOKEN  TELEGRAM_CHAT_ID  (notify via Telegram)
     EXTRA_IMAGES (default: boot.img vendor_boot.img; add dtbo.img here)
     GH_RELEASE_REPO (default Transsion-G81/releases)  GH_TOKEN / GITHUB_TOKEN
     SF_USER (default opekfurina)  SF_PROJECT (default transsion-g81)
     SF_HOST (default frs.sourceforge.net)  SF_FOLDER

WITH_XGSI_LOGS=true installs the XGSI boot/dmesg log capture scripts into the
rom (the menu has a checkbox for it).  It is read from device.mk at
product-config time, so clear out/target/product/<device> before toggling it on
a tree that already built.

The make lines are appended to the product makefile just before the build and
removed again afterwards, so the tree stays clean; a line the tree already
carries is not duplicated.  If a requested line cannot be placed (or the
makefile is missing) the build stops instead of continuing with the wrong
config.

GMS modes: every selected device is built once per mode, in the fixed order
vanilla -> gapps -> microg, limited to the modes the tree actually provides.
Each mode builds only its own pass, so "gapps" is a single GApps build and does
not build vanilla first; pick "vanilla+gapps" or "all" to build several passes
in one run (the menu's GMS row has the same choices).  LineageOS uses our
device.mk gate: gapps bakes MindTheGapps (vendor/gapps) and microg bakes microG
(vendor/partner_gms - LineageOS already ships microG-only signature spoofing, so
no frameworks patch is needed).  Other ROMs are probed: if the tree ships a
GApps and/or microG payload (and exposes a switch for it), that mode is offered
and the ROM's own switch is used - nothing per-ROM is hardcoded.  gapps and
microG are mutually exclusive.  The product out dir is cleared when the mode
changes (a per-product .trang81-gms stamp tracks it).  Artifacts land in
out/tranG81-releases/<variant>/<mode>/ and non-vanilla zips get a
-GAPPS/-MICROG suffix; boot images are collected on the first pass of a run
(identical across modes).  The menu has a GMS row (keys g / left / right).

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

# fold a requested mode list (comma/space/+ separated, repeated) into the fixed
# build order vanilla -> gapps -> microg, de-duplicated.  Each pass stands alone
# (vanilla is NOT forced: "gapps" builds only the GApps product); "all" = the
# three passes, "vanilla+gapps" = that pair, "none"/"vanilla" = vanilla only.
# Sets GMS_MODE_LIST.
normalize_gms() {
  local t
  local -a src=() part=()
  local -A sel=()
  for t in "$@"; do
    part=()
    IFS=', +' read -r -a part <<<"$t"
    src+=("${part[@]+"${part[@]}"}")
  done
  for t in "${src[@]+"${src[@]}"}"; do
    [[ -n "$t" ]] || continue
    case "$t" in
      all)          sel[vanilla]=1; sel[gapps]=1; sel[microg]=1 ;;
      none|vanilla) sel[vanilla]=1 ;;
      gapps)        sel[gapps]=1 ;;
      microg)       sel[microg]=1 ;;
      *)            die "bad --gms value '$t' (use vanilla|gapps|microg|vanilla+gapps|all)" ;;
    esac
  done
  GMS_MODE_LIST=()
  for t in vanilla gapps microg; do
    [[ -n "${sel[$t]:-}" ]] || continue
    [[ " $ROM_MODES " == *" $t "* ]] || { warn "$ROM_NAME has no '$t' pass - skipping"; continue; }
    GMS_MODE_LIST+=("$t")
  done
  [[ ${#GMS_MODE_LIST[@]} -gt 0 ]] || GMS_MODE_LIST=(vanilla)
}

# export the env the ROM reads to pick the GMS payload for this pass.
set_gms_env() {
  local v e
  for v in $ROM_GMS_VARS; do unset "$v"; done
  for e in $(rom_gms_env "$1"); do export "$e"; done
  return 0
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

# drop microG modules listed in PRODUCT_PACKAGES but never shipped (full builds reject them)
prune_microg_unshipped() {
  local dir="$ANDROID_ROOT/vendor/partner_gms" mk m tmp pat
  mk="$dir/microg.mk"
  [[ -r "$mk" ]] || return 0
  for m in IchnaeaNlpBackend NominatimGeocoderBackend; do
    pat="^[[:space:]]*$m[[:space:]]*\\\\?[[:space:]]*\$"
    grep -qE "$pat" "$mk" || continue
    grep -rqE "name[[:space:]]*:[[:space:]]*\"$m\"" "$dir" \
      --include='Android.bp' --include='Android.mk' && continue
    tmp="$mk.trang81.tmp"
    grep -vE "$pat" "$mk" > "$tmp" && mv "$tmp" "$mk" \
      || { rm -f "$tmp"; warn "could not prune $m from microg.mk"; continue; }
    info "microg   : dropped unshipped module $m from microg.mk"
  done
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
  local short="${product#$ROM_PREFIX}" fail=0 bn

  for d in "$ANDROID_ROOT/$devtree" "$ANDROID_ROOT/$vendortree"; do
    [[ -d "$d" ]] || { err "missing tree: $d"; fail=1; }
  done
  [[ "$fail" -eq 0 ]] || return 1

  if [[ ! -f "$ANDROID_ROOT/$devtree/$ROM_PREFIX$short.mk" ]]; then
    err "missing product makefile: $devtree/$ROM_PREFIX$short.mk"
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

# --------------------------------------------------------- release mirrors ----
# GitHub Releases + SourceForge, fed the same collected files (rom zip plus
# boot/vendor_boot and EXTRA_IMAGES).  Each codename owns one GitHub release and
# one SourceForge subfolder; files are replaced, never versioned.

# the codename a bare file name belongs to; the longest DEVICES key wins, so
# boot-X6531B.img is X6531B and not X6531.
codename_of() {
  local name="$1" e key best=""
  for e in "${DEVICES[@]}"; do
    key="${e%%|*}"; key="${key#$ROM_PREFIX}"
    [[ "$name" == *"$key"* ]] || continue
    (( ${#key} > ${#best} )) && best="$key"
  done
  printf '%s' "$best"
}

# GitHub: prepare the codename's release once per run, then upload (replace) one
# file.  gh authenticates itself (GH_TOKEN / GITHUB_TOKEN / stored login).
gh_publish() {
  local file="$1" name="$2" tag="$3" notes="${4:-}"
  if [[ "$DRY_RUN" == "yes" ]]; then
    say "    gh release create/edit $tag --repo $GH_RELEASE_REPO   (title $tag)"
    say "    gh release upload $tag $file --repo $GH_RELEASE_REPO --clobber"
    return 0
  fi
  if [[ -z "${GH_MIRRORED[$tag]:-}" ]]; then
    if gh release view "$tag" --repo "$GH_RELEASE_REPO" >/dev/null 2>&1; then
      gh release edit "$tag" --repo "$GH_RELEASE_REPO" --title "$tag" --notes "$notes" >/dev/null 2>&1 \
        || warn "github: could not update release $tag"
    elif ! gh release create "$tag" --repo "$GH_RELEASE_REPO" --title "$tag" --notes "$notes" >/dev/null; then
      err "github: could not create release $tag"
      return 1
    fi
    GH_MIRRORED[$tag]=1
  fi
  if gh release upload "$tag" "$file" --repo "$GH_RELEASE_REPO" --clobber >/dev/null; then
    ok "github  $tag <- $name"
    GH_UPLOADED=$((GH_UPLOADED + 1))
    MIRROR_LINKS+=("https://github.com/$GH_RELEASE_REPO/releases/tag/$tag $name (github)")
  else
    err "github: upload failed for $name ($tag)"
    return 1
  fi
}

sf_remote_dir() { printf '/home/frs/project/%s/%s/%s' "$SF_PROJECT" "$SF_FOLDER" "$1"; }

# SourceForge: make the codename's folder (if needed) and rsync the file in.
sf_publish() {
  local file="$1" name="$2" tag="$3" rdir rurl
  if [[ -z "$SF_FOLDER" ]]; then
    err "sourceforge: no folder chosen (use --sf-folder NAME or the menu)"
    return 1
  fi
  rdir="$(sf_remote_dir "$tag")"
  rurl="$SF_USER@$SF_HOST:$rdir"
  if [[ "$DRY_RUN" == "yes" ]]; then
    say "    ssh $SF_USER@$SF_HOST mkdir -p $rdir"
    say "    rsync -e ssh $file $rurl/"
    return 0
  fi
  if ! ssh -o BatchMode=yes "$SF_USER@$SF_HOST" "mkdir -p '$rdir'"; then
    err "sourceforge: mkdir failed ($rdir)"
    return 1
  fi
  if rsync -e "ssh -o BatchMode=yes" --partial "$file" "$rurl/"; then
    ok "sourceforge  $SF_FOLDER/$tag <- $name"
    SF_UPLOADED=$((SF_UPLOADED + 1))
    MIRROR_LINKS+=("https://sourceforge.net/projects/$SF_PROJECT/files/$SF_FOLDER/$tag/ $name (sourceforge)")
  else
    err "sourceforge: upload failed for $name ($tag)"
    return 1
  fi
}

# send one file to every enabled mirror; the codename tag comes from the caller.
publish_file() {
  local file="$1" name="$2" tag="$3" notes="${4:-}" rc=0
  [[ -n "$tag" ]] || { err "cannot tell the codename of $name"; return 1; }
  [[ "$DO_GH" == "yes" ]] && { gh_publish "$file" "$name" "$tag" "$notes" || rc=1; }
  [[ "$DO_SF" == "yes" ]] && { sf_publish "$file" "$name" "$tag" || rc=1; }
  return "$rc"
}

# ssh ls the project's SourceForge folders (its FRS root), minus the web tree.
sf_list_folders() {
  ssh -o BatchMode=yes "$SF_USER@$SF_HOST" "ls -1 /home/frs/project/$SF_PROJECT" 2>/dev/null \
    | grep -vE '^(htdocs|\.)'
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

# ---- reverting the patches our trees apply ----------------------------------
# <devtree>/patches/<set>/ holds patches the device's vendorsetup.sh drops into
# another project of the tree.  --revert-patches / the TUI 'r' key take them
# back off (reverse-apply) as maintenance.  A later build re-applies them
# through envsetup unless PATCH_SHADE=0 / PATCH_NFC stays unset.
declare -A PATCH_SET_REPO=(
  [systemui]="frameworks/base"     # device/infinix/X6532/patches/systemui
  [nfc]="hardware/nxp/nfc"         # device/tecno/KL5/patches/nfc
)

# reverse-apply one set; a patch that is not applied is skipped, so running it
# twice is safe.  Returns 1 if any patch could not be reverted.
revert_patch_set() {
  local repo="$1" pdir="$2" p name rc=0
  local r="$ANDROID_ROOT/$repo"
  for p in "$pdir"/[0-9][0-9][0-9][0-9]-*.patch; do
    [[ -f "$p" ]] || continue
    name="$(basename "$p")"
    if git -C "$r" apply --reverse --check "$p" 2>/dev/null; then
      if git -C "$r" apply --reverse "$p" 2>/dev/null; then ok "reverted  $name"
      else err "could not revert $name (git apply --reverse failed)"; rc=1; fi
    elif git -C "$r" apply --check "$p" 2>/dev/null; then
      say "          $name: not applied"
    elif patch -p1 --reverse --dry-run --fuzz=3 -d "$r" -i "$p" >/dev/null 2>&1; then
      if patch -p1 --reverse --fuzz=3 --no-backup-if-mismatch -d "$r" -i "$p" >/dev/null 2>&1; then
        ok "reverted  $name (patch -R)"
      else err "could not revert $name (patch -R failed)"; rc=1; fi
    elif patch -p1 --dry-run --fuzz=3 -d "$r" -i "$p" >/dev/null 2>&1; then
      say "          $name: not applied"
    else
      warn "$name: neither applied nor revertible - $repo drifted, fix by hand"; rc=1
    fi
  done
  return "$rc"
}

# revert every set the selected devices' trees apply, once per distinct tree
# (X6531B shares device/infinix/X6531, KL5n device/tecno/KL5).
revert_selected_patches() {
  local entry product devtree set pdir seen=" " rc=0 n
  for entry in "${SELECTED[@]}"; do
    IFS='|' read -r product devtree _ <<<"$entry"
    [[ "$seen" == *" $devtree "* ]] && continue
    seen+="$devtree "
    n=0
    for pdir in "$ANDROID_ROOT/$devtree/patches"/*/; do
      [[ -d "$pdir" ]] || continue
      set="$(basename "$pdir")"
      n=$((n + 1))
      if [[ -z "${PATCH_SET_REPO[$set]:-}" ]]; then
        warn "$devtree/patches/$set: target repo unknown - skipped (add it to PATCH_SET_REPO)"
        rc=1; continue
      fi
      say ""
      info "$devtree/patches/$set -> ${PATCH_SET_REPO[$set]}"
      revert_patch_set "${PATCH_SET_REPO[$set]}" "$pdir" || rc=1
    done
    (( n )) || { say ""; warn "$devtree/patches: no patch sets found"; }
  done
  return "$rc"
}

# a device build runs for an hour; surface why it died instead of "see the log".
# ninja cancels every action it still has queued once it stops, so the tail of a
# failed log is a wall of "error: action cancelled when ninja exited"; the cause is
# the first FAILED block that is not one of those cancellations (the cascade's
# Error: line is always the 3rd line of a block).
show_build_errors() {
  local log="$1" blk hits
  [[ -f "$log" ]] || return 0
  blk=$(awk '
    /^FAILED:/ {
      if (done) next
      if (inb) { print b; done=1; next }
      inb=1; b=$0; n=0; next
    }
    inb {
      b = b "\n" $0; n++
      if (n == 2 && $0 ~ /action cancelled when ninja exited/) { inb=0; next }
      if (n >= 4) { print b; done=1; inb=0 }
    }
    END { if (inb) print b }
  ' "$log")
  if [[ -n "$blk" ]]; then
    say "   ---- first real error (${log##*/}) ----"
    printf '%s\n' "$blk" | sed 's/^/   /'
    return 0
  fi
  hits=$(grep -nE 'error:|fatal error|ninja: build stopped' "$log" 2>/dev/null \
         | grep -v 'action cancelled when ninja exited' | head -n 12)
  if [[ -n "$hits" ]]; then
    say "   ---- first errors (${log##*/}) ----"
    printf '%s\n' "$hits" | sed 's/^/   /'
  else
    say "   ---- no real error; build was most likely killed (${log##*/}) ----"
    tail -n 8 "$log" | sed 's/^/   /'
  fi
}

# LineageOS 23.x lunch() wants a release config (bp4a, trunk_staging, ...) that is
# not optional.  Prefer --release / TARGET_RELEASE, else the pin the ROM ships
# (ROM_RELEASE_FILE), else a release the tree lists for this product, else
# AOSP's default.  ROMs whose lunch takes no release return empty.
resolve_release() {
  local product="$1" f rel
  [[ "$ROM_LUNCH_STYLE" == "release" ]] || return 0
  if [[ -n "$LUNCH_RELEASE" ]]; then printf '%s' "$LUNCH_RELEASE"; return 0; fi
  f="$ANDROID_ROOT/$ROM_RELEASE_FILE"
  if [[ -n "$ROM_RELEASE_FILE" && -r "$f" ]]; then
    rel=$(sed -n 's/^[[:space:]]*aosp_target_release[[:space:]]*=[[:space:]]*\([A-Za-z0-9_.-]*\).*/\1/p' "$f" | tail -n1)
    [[ -n "$rel" ]] && { printf '%s' "$rel"; return 0; }
  fi
  if [[ -n "$ROM_RELEASE_CMD" ]] && declare -F "$ROM_RELEASE_CMD" >/dev/null 2>&1; then
    rel=$("$ROM_RELEASE_CMD" "$product" 2>/dev/null | tr ' \t' '\n\n' | grep -E '^[A-Za-z0-9_.-]+$' | head -n1)
    [[ -n "$rel" ]] && { printf '%s' "$rel"; return 0; }
  fi
  printf '%s' 'trunk_staging'
}

# ---- product-makefile line injection ----------------------------------------
# A ROM profile (or the caller) can need a line at the bottom of the device's
# product makefile that must not be committed, because the tree is shared by
# every ROM.  We append it before lunch and put the file back afterwards; the
# pristine copy is stashed next to it, so a run killed mid-build is repaired by
# the next run and `repo sync`/`git status` stay clean.
PRODUCT_LINES_MARK="# tranG81: appended for the build by build-all.sh (auto-removed)"

# lines to append for a product: the ROM profile's own, then PRODUCT_EXTRA_LINES
# (or the per-device PRODUCT_EXTRA_LINES_<device> if set, e.g. ..._X6532).
product_extra_lines() {
  local device="$1" v="PRODUCT_EXTRA_LINES_${1}" per=""
  local -a l=()
  if declare -p "$v" >/dev/null 2>&1; then per="${!v}"; fi
  [[ -n "$ROM_PRODUCT_EXTRA" ]] && l+=("$ROM_PRODUCT_EXTRA")
  if [[ -n "$per" ]]; then l+=("$per")
  elif [[ -n "$PRODUCT_EXTRA_LINES" ]]; then l+=("$PRODUCT_EXTRA_LINES")
  fi
  [[ ${#l[@]} -gt 0 ]] && printf '%s\n' "${l[@]}" | sed '/^$/d'
  return 0
}

# put the stashed pristine product makefile back (no-op when nothing was stolen).
restore_product_lines() {
  local mk="$1" orig
  [[ -n "$mk" ]] || return 0
  orig="$mk.tranG81.orig"
  [[ -f "$orig" ]] && mv -f "$orig" "$mk"
  INJECTED_MK=""
  return 0
}

# every requested line must actually be present in the product makefile.
verify_product_lines() {
  local mk="$1" line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    grep -qxF -- "$line" "$mk" || { err "product line did not land in ${mk#$ANDROID_ROOT/}: $line"; return 1; }
  done <<<"$2"
  return 0
}

inject_product_lines() {
  local mk="$1" lines="$2" orig="" miss="" line
  orig="$mk.tranG81.orig"
  restore_product_lines "$mk"           # drop a block a previous run left behind
  [[ -n "$lines" ]] || return 0
  [[ -f "$mk" ]] || { err "cannot inject product lines: ${mk#$ANDROID_ROOT/} missing"; return 1; }
  # a line the tree already carries is left alone; only the missing ones are added
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    grep -qxF -- "$line" "$mk" || miss+="${miss:+$'\n'}$line"
  done <<<"$lines"
  if [[ -n "$miss" ]]; then
    cp "$mk" "$orig"
    printf '\n%s\n%s\n' "$PRODUCT_LINES_MARK" "$miss" >>"$mk"
    INJECTED_MK="$mk"
    info "product lines injected into ${mk#$ANDROID_ROOT/}:"
    printf '%s\n' "$miss" | sed 's/^/     /'
  else
    info "product lines already present in ${mk#$ANDROID_ROOT/} - tree left as-is"
  fi
  # the ROM reads these at product-config time: fail rather than build with a
  # config the tree never actually received
  verify_product_lines "$mk" "$lines"
}

run_build() {
  local product="$1" variant="$2" nfc="$3" devtree="$4" log="$5"
  local rc gmsenv="" extra pmk="" mk=()
  extra="$(product_extra_lines "${product#$ROM_PREFIX}")"
  mapfile -t mk < <(rom_build_args)

  [[ -n "$LUNCH_RELEASE" ]] || LUNCH_RELEASE="$(resolve_release "$product")"

  # the ROM reads this at product-config time to pick the GMS payload.
  set_gms_env "$GMS_MODE"
  gmsenv="$(rom_gms_env "$GMS_MODE")"

  if [[ "$DRY_RUN" == "yes" ]]; then
    say "    cd $ANDROID_ROOT"
    say "    source build/envsetup.sh   (PATCH_NFC=$([[ "$nfc" == 1 ]] && echo true || echo unset)${gmsenv:+ $gmsenv})"
    say "    $ROM_SETUP_CMD $(rom_setup_args "$product" "$variant")"
    say "    ${mk[*]}"
    if [[ -n "$extra" ]]; then
      say "    + append to the bottom of $devtree/$product.mk (not committed):"
      printf '%s\n' "$extra" | sed 's/^/        /'
    fi
    return 0
  fi

  cd "$ANDROID_ROOT" || return 1

  # the ROM reads these at product-config time; the tree is restored below.
  # inject_product_lines verifies the lines really landed, so a tree that cannot
  # carry them is not built with a silently wrong config.
  pmk="$ANDROID_ROOT/$devtree/$product.mk"
  if ! inject_product_lines "$pmk" "$extra"; then
    restore_product_lines "$pmk"
    return 1
  fi

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
    # shellcheck disable=SC2086
    $ROM_SETUP_CMD $(rom_setup_args "$product" "$variant"); rc=$?
    if [[ "$rc" -ne 0 ]]; then
      warn "$ROM_SETUP_CMD $(rom_setup_args "$product" "$variant") failed${LUNCH_RELEASE:+ - pass --release NAME}"
      [[ -n "$ROM_RELEASE_FILE" ]] && warn "   release pin: $ROM_RELEASE_FILE"
    fi
  fi
  if [[ "$rc" -eq 0 && "$nfc" == "1" ]]; then
    verify_nfc_patches "$devtree" || rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    say "+ ${mk[*]}   (log: ${log#$ANDROID_ROOT/})"
    "${mk[@]}" 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"
  fi
  set -u
  restore_product_lines "$pmk"
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

  tag="${product#$ROM_PREFIX}"
  mkdir -p "$dir" || return 1

  msuf=""
  [[ "$GMS_MODE" != vanilla ]] && msuf="-$(gms_label "$GMS_MODE")"

  zip=$(ls -1t "$out"/$ROM_ZIP_GLOB 2>/dev/null | head -n1)
  if [[ -z "$zip" || ! -f "$zip" ]]; then
    err "no $ROM_ZIP_GLOB under out/target/product/$device"
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
  # across GMS modes - collect them on the first pass of the set only (that is
  # the vanilla pass when it is selected), else the same file would be uploaded
  # once per mode.  (Both products of a shared out dir write the same file name
  # there, so tag every copy with the product.)
  [[ "$GMS_MODE" == "${GMS_MODE_LIST[0]}" ]] || return 0
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
  local tag="${product#$ROM_PREFIX}"
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

# choose the SourceForge folder interactively: list the project's folders, pick
# one by number or name, or "n" to create a new one.  Writes SF_FOLDER.
sf_pick_folder() {
  local -a folders=(); local i choice new
  mapfile -t folders < <(sf_list_folders)
  say ""
  info "SourceForge folder under /home/frs/project/$SF_PROJECT"
  for i in "${!folders[@]}"; do say "  $((i + 1))) ${folders[$i]}"; done
  (( ${#folders[@]} )) || say "  (none found - check your SourceForge SSH key, or name a new folder)"
  say "  n) new folder"
  choice="$(ask "folder number, name, or n" "${SF_FOLDER:-n}")"
  case "$choice" in
    n|N|new)
      new="$(ask "new folder name" "${SF_FOLDER:-}")"
      [[ -n "$new" ]] || { warn "sourceforge: no folder name given"; return 1; }
      SF_FOLDER="$new" ;;
    ''|*[!0-9]*) SF_FOLDER="$choice" ;;
    *) i=$((choice - 1))
       if [[ -n "${folders[$i]:-}" ]]; then SF_FOLDER="${folders[$i]}"
       else warn "sourceforge: no folder $choice"; return 1; fi ;;
  esac
  ok "sourceforge folder: $SF_FOLDER"
}

# Pure-bash full-screen TUI: every key (arrows included) arrives through
# read -rsn1, so nothing has to be installed - no dialog, whiptail or fzf.
# The tty state is saved up front and restored on every exit path.
TUI_FOCUS=0
TUI_VARIANT="user"
TUI_UPLOAD="yes"
TUI_GH="no"
TUI_SF="no"
TUI_XGSI="no"
TUI_GMS=0
TUI_STATUS=""
TUI_LINES=""
TUI_STTY=""
TUI_VARIANTS=(user userdebug eng)
declare -a TUI_GMS_MODES=() TUI_GMS_LABELS=()
declare -a MENU_GMS_OPTS=() MENU_GMS_WANTS=()
declare -a TUI_SEL=()
TUI_ROM=0

tui_cleanup() {
  [[ -n "$TUI_STTY" ]] && stty "$TUI_STTY" </dev/tty 2>/dev/null
  TUI_STTY=""
  printf '\033[?25h\033[0m'
  trap - INT TERM HUP
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
    e|E)  printf 'edit' ;;
    r|R)  printf 'revert' ;;
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

# move the ROM row by $1 (right/left) and reload that profile's devices + menus
tui_cycle_rom() {
  local dir=1
  [[ "$1" == left ]] && dir=-1
  TUI_ROM=$(((TUI_ROM + dir + ${#ROMS[@]}) % ${#ROMS[@]}))
  set_rom "${ROMS[$TUI_ROM]}"
  (( TUI_GMS < ${#TUI_GMS_MODES[@]} )) || TUI_GMS=0
}

# Edit the make lines appended (for the build only) to the product makefile.
# Raw TUI mode cannot read a line, so drop back to the saved tty settings for
# the prompt and restore raw mode before redrawing.
tui_edit_lines() {
  local l out="" typed=0
  stty "$TUI_STTY" </dev/tty 2>/dev/null
  printf '\033[?25h\033[2J\033[H'
  printf '  %smake lines%s appended to the bottom of the product makefile\n' "$c_cyn" "$c_reset"
  printf '  for the build only - removed again afterwards, so the tree stays clean.\n\n'
  if [[ -n "$TUI_LINES" ]]; then
    printf '  current:\n'; printf '%s\n' "$TUI_LINES" | sed 's/^/    /'
  else
    printf '  current: (none)\n'
  fi
  printf '\n  type one line per entry, blank line to finish, "-" to clear.\n'
  printf '  e.g.  AXION_PROCESSOR := MediaTek_Helio_G81\n'
  printf '        AXION_MAINTAINER := your_name\n\n'
  while IFS= read -r l </dev/tty; do
    [[ -z "$l" ]] && break
    typed=1
    [[ "$l" == "-" ]] && { out=""; break; }
    out+="${out:+$'\n'}$l"
  done
  (( typed )) && TUI_LINES="$out"
  stty -echo -icanon min 1 time 0 </dev/tty 2>/dev/null
  printf '\033[2J\033[?25l'
}

# pick the SourceForge folder from the TUI: drop to cooked mode, reuse the plain
# picker, then restore raw mode before redrawing.
tui_sf_folder() {
  stty "$TUI_STTY" </dev/tty 2>/dev/null
  printf '\033[?25h\033[2J\033[H'
  sf_pick_folder || true
  printf '\n  press enter to return'
  IFS= read -r _ </dev/tty || true
  stty -echo -icanon min 1 time 0 </dev/tty 2>/dev/null
  printf '\033[2J\033[?25l'
}

tui_render() {
  local n=${#DEVICES[@]} i lab short row
  printf '\033[H'
  printf '  %s%stranG81%s - build + release\033[K\n' "$c_cyn" "$c_bold" "$c_reset" "$c_reset"
  printf '  %s%s%s\033[K\n' "$c_cyn" '────────────────────────────────────────────────────────────' "$c_reset"
  printf '\033[K\n'

  row="$(tui_mark 0)"
  row+="rom      "
  (( TUI_FOCUS == 0 )) && row+="${c_bold}< $ROM >${c_reset}" || row+="< $ROM >"
  printf '%s\033[K\n' "$row"
  printf '\033[K\n'

  row="$(tui_mark 1)"
  row+="variant  "
  for lab in "${TUI_VARIANTS[@]}"; do
    if [[ "$lab" == "$TUI_VARIANT" ]]; then row+="${c_rev} $lab ${c_reset} "
    else row+=" $lab  "; fi
  done
  printf '%s\033[K\n' "$row"
  printf '\033[K\n'

  printf '   %sdevices%s  (space toggles, a all, n none)\033[K\n' "$c_cyn" "$c_reset"
  for ((i = 0; i < n; i++)); do
    short="${DEVICES[$i]%%|*}"; short="${short#$ROM_PREFIX}"
    row="$(tui_mark $((i + 2)))"
    (( TUI_SEL[i] )) && row+="[x] " || row+="[ ] "
    (( TUI_FOCUS == i + 2 )) && row+="${c_bold}${short}${c_reset}" || row+="$short"
    printf '%s\033[K\n' "$row"
  done
  printf '\033[K\n'

  row="$(tui_mark $((n + 2)))"
  [[ "$TUI_UPLOAD" == "yes" ]] && row+="[x] " || row+="[ ] "
  (( TUI_FOCUS == n + 2 )) && row+="${c_bold}upload to Buzzheavier${c_reset}" || row+="upload to Buzzheavier"
  printf '%s\033[K\n' "$row"

  row="$(tui_mark $((n + 3)))"
  [[ "$TUI_XGSI" == "yes" ]] && row+="[x] " || row+="[ ] "
  (( TUI_FOCUS == n + 3 )) && row+="${c_bold}xgsi boot/dmesg logs${c_reset}" || row+="xgsi boot/dmesg logs"
  printf '%s\033[K\n' "$row"

  row="$(tui_mark $((n + 4)))"
  row+="gms  "
  (( TUI_FOCUS == n + 4 )) && row+="${c_bold}< ${TUI_GMS_LABELS[$TUI_GMS]} >${c_reset}" || row+="< ${TUI_GMS_LABELS[$TUI_GMS]} >"
  printf '%s\033[K\n' "$row"

  row="$(tui_mark $((n + 5)))"
  if [[ -n "$TUI_LINES" ]]; then lab="${TUI_LINES//$'\n'/; }"; (( ${#lab} > 44 )) && lab="${lab:0:41}..."
  else lab="(none)"; fi
  (( TUI_FOCUS == n + 5 )) && row+="${c_bold}make lines: $lab${c_reset}" || row+="make lines: $lab"
  printf '%s\033[K\n' "$row"

  row="$(tui_mark $((n + 6)))"
  [[ "$TUI_GH" == "yes" ]] && row+="[x] " || row+="[ ] "
  (( TUI_FOCUS == n + 6 )) && row+="${c_bold}github release ($GH_RELEASE_REPO)${c_reset}" || row+="github release ($GH_RELEASE_REPO)"
  printf '%s\033[K\n' "$row"

  row="$(tui_mark $((n + 7)))"
  [[ "$TUI_SF" == "yes" ]] && row+="[x] " || row+="[ ] "
  (( TUI_FOCUS == n + 7 )) && row+="${c_bold}sourceforge ($SF_PROJECT)${c_reset}" || row+="sourceforge ($SF_PROJECT)"
  printf '%s\033[K\n' "$row"

  row="$(tui_mark $((n + 8)))"
  (( TUI_FOCUS == n + 8 )) && row+="${c_bold}sf folder: ${SF_FOLDER:-<pick>}${c_reset}" || row+="sf folder: ${SF_FOLDER:-<pick>}"
  printf '%s\033[K\n' "$row"
  printf '\033[K\n'

  printf '   %sup/down%s move   %sspace%s toggle   %sleft/right%s rom/variant/gms   %sa%s all   %sn%s none\033[K\n' \
    "$c_cyn" "$c_reset" "$c_cyn" "$c_reset" "$c_cyn" "$c_reset" "$c_cyn" "$c_reset" "$c_cyn" "$c_reset"
  printf '   %sx%s xgsi   %sg%s gms   %se%s make lines   %sr%s revert   %senter%s start/choose   %sq%s quit\033[K\n' \
    "$c_cyn" "$c_reset" "$c_cyn" "$c_reset" "$c_cyn" "$c_reset" "$c_cyn" "$c_reset" "$c_cyn" "$c_reset" "$c_cyn" "$c_reset"
  [[ -n "$TUI_STATUS" ]] && printf '   %s%s%s\033[K\n' "$c_yel" "$TUI_STATUS" "$c_reset" || printf '\033[K\n'
  printf '\033[J'
}

tui_run() {
  local n=${#DEVICES[@]} i key short req="" all=1 any
  TUI_FOCUS=0; TUI_STATUS=""; TUI_UPLOAD="yes"; TUI_GMS=0; REVERT_PATCHES="no"
  TUI_GH="$DO_GH"; TUI_SF="$DO_SF"
  TUI_ROM=0
  for i in "${!ROMS[@]}"; do [[ "${ROMS[$i]}" == "$ROM" ]] && TUI_ROM=$i; done
  TUI_SEL=()
  for ((i = 0; i < n; i++)); do TUI_SEL[i]=1; done
  [[ -n "${VARIANT:-}" ]] && TUI_VARIANT="$VARIANT"
  [[ -n "${WITH_XGSI_LOGS:-}" ]] && TUI_XGSI="yes" || TUI_XGSI="no"
  TUI_LINES="${PRODUCT_EXTRA_LINES:-}"

  TUI_STTY="$(stty -g </dev/tty 2>/dev/null)"
  stty -echo -icanon min 1 time 0 </dev/tty 2>/dev/null
  trap 'tui_cleanup; exit 130' INT TERM HUP
  printf '\033[2J\033[?25l'
  tui_render

  while :; do
    key="$(tui_key)" || { tui_cleanup; die "no input"; }
    TUI_STATUS=""
    case "$key" in
      up)   (( TUI_FOCUS > 0 )) && TUI_FOCUS=$((TUI_FOCUS - 1)) ;;
      down) (( TUI_FOCUS < n + 8 )) && TUI_FOCUS=$((TUI_FOCUS + 1)) ;;
      left|right)
        if   (( TUI_FOCUS == 0 ));     then tui_cycle_rom "$key"
        elif (( TUI_FOCUS == 1 ));     then [[ "$key" == left ]] && tui_cycle -1 || tui_cycle 1
        elif (( TUI_FOCUS == n + 4 )); then
          if [[ "$key" == left ]]; then TUI_GMS=$(((TUI_GMS + ${#TUI_GMS_MODES[@]} - 1) % ${#TUI_GMS_MODES[@]}))
          else TUI_GMS=$(((TUI_GMS + 1) % ${#TUI_GMS_MODES[@]})); fi
        fi ;;
      space)
        if   (( TUI_FOCUS == 0 ));     then tui_cycle_rom right
        elif (( TUI_FOCUS == 1 ));     then tui_cycle 1
        elif (( TUI_FOCUS == n + 2 )); then [[ "$TUI_UPLOAD" == yes ]] && TUI_UPLOAD="no" || TUI_UPLOAD="yes"
        elif (( TUI_FOCUS == n + 3 )); then [[ "$TUI_XGSI" == yes ]] && TUI_XGSI="no" || TUI_XGSI="yes"
        elif (( TUI_FOCUS == n + 4 )); then TUI_GMS=$(((TUI_GMS + 1) % ${#TUI_GMS_MODES[@]}))
        elif (( TUI_FOCUS == n + 5 )); then tui_edit_lines
        elif (( TUI_FOCUS == n + 6 )); then [[ "$TUI_GH" == yes ]] && TUI_GH="no" || TUI_GH="yes"
        elif (( TUI_FOCUS == n + 7 )); then [[ "$TUI_SF" == yes ]] && TUI_SF="no" || TUI_SF="yes"
        elif (( TUI_FOCUS == n + 8 )); then tui_sf_folder
        else TUI_SEL[TUI_FOCUS - 2]=$((1 - TUI_SEL[TUI_FOCUS - 2]))
        fi ;;
      upload) [[ "$TUI_UPLOAD" == yes ]] && TUI_UPLOAD="no" || TUI_UPLOAD="yes" ;;
      xgsi)   [[ "$TUI_XGSI" == yes ]] && TUI_XGSI="no" || TUI_XGSI="yes" ;;
      gms)    TUI_GMS=$(((TUI_GMS + 1) % ${#TUI_GMS_MODES[@]})) ;;
      edit)   tui_edit_lines ;;
      revert)
        any=0
        for ((i = 0; i < n; i++)); do (( TUI_SEL[i] )) && any=1; done
        if (( any == 0 )); then TUI_STATUS="select at least one device"; tui_render; continue; fi
        REVERT_PATCHES="yes"
        break ;;
      all)  for ((i = 0; i < n; i++)); do TUI_SEL[i]=1; done ;;
      none) for ((i = 0; i < n; i++)); do TUI_SEL[i]=0; done ;;
      enter)
        if (( TUI_FOCUS == n + 5 )); then tui_edit_lines; tui_render; continue; fi
        if (( TUI_FOCUS == n + 6 )); then [[ "$TUI_GH" == yes ]] && TUI_GH="no" || TUI_GH="yes"; tui_render; continue; fi
        if (( TUI_FOCUS == n + 7 )); then [[ "$TUI_SF" == yes ]] && TUI_SF="no" || TUI_SF="yes"; tui_render; continue; fi
        if (( TUI_FOCUS == n + 8 )); then tui_sf_folder; tui_render; continue; fi
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
    short="${DEVICES[$i]%%|*}"; short="${short#$ROM_PREFIX}"
    (( TUI_SEL[i] )) && req+="${req:+,}$short" || all=0
  done
  tui_cleanup
  printf '\033[2J\033[H'
  VARIANT="$TUI_VARIANT"
  DO_UPLOAD="$TUI_UPLOAD"
  DO_GH="$TUI_GH"
  DO_SF="$TUI_SF"
  [[ "$TUI_XGSI" == "yes" ]] && WITH_XGSI_LOGS="true" || WITH_XGSI_LOGS=""
  GMS_WANT=("${TUI_GMS_MODES[$TUI_GMS]}")
  PRODUCT_EXTRA_LINES="$TUI_LINES"
  [[ "$all" == 1 ]] && REQUESTED="all" || REQUESTED="$req"
}

# plain ask() flow, used when there is no terminal to draw on
menu_ask() {
  local v i short gm gi xd r

  say ""
  info "rom"
  select r in "${ROMS[@]}"; do
    [[ -n "${r:-}" ]] && break
    warn "pick a number"
  done
  [[ "$r" == "$ROM" ]] || set_rom "$r"

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
      short="${DEVICES[$i]%%|*}"; short="${short#$ROM_PREFIX}"
      say "  $((i + 1))) $short"
    done
    REQUESTED="$(ask "numbers, comma separated" "1,2,3,4,5")"
  fi

  say ""
  if [[ "$(ask "revert the patches our trees apply, instead of building?" "n")" =~ ^[Yy] ]]; then
    REVERT_PATCHES="yes"
    return
  fi

  [[ "$(ask "upload to Buzzheavier?" "y")" =~ ^[Yy] ]] && DO_UPLOAD="yes" || DO_UPLOAD="no"

  [[ "$(ask "publish to GitHub release ($GH_RELEASE_REPO)?" "n")" =~ ^[Yy] ]] && DO_GH="yes" || DO_GH="no"
  [[ "$(ask "publish to SourceForge ($SF_PROJECT)?" "n")" =~ ^[Yy] ]] && DO_SF="yes" || DO_SF="no"
  if [[ "$DO_SF" == "yes" && -z "$SF_FOLDER" ]]; then sf_pick_folder || DO_SF="no"; fi

  say ""
  info "gms modes"
  select gm in "${MENU_GMS_OPTS[@]}"; do
    [[ -n "${gm:-}" ]] && break
    warn "pick a number"
  done
  for gi in "${!MENU_GMS_OPTS[@]}"; do
    [[ "${MENU_GMS_OPTS[$gi]}" == "$gm" ]] && GMS_WANT=("${MENU_GMS_WANTS[$gi]}")
  done

  [[ -n "$WITH_XGSI_LOGS" ]] && xd="y" || xd="n"
  [[ "$(ask "xgsi boot/dmesg logs?" "$xd")" =~ ^[Yy] ]] && WITH_XGSI_LOGS="true" || WITH_XGSI_LOGS=""

  say ""
  PRODUCT_EXTRA_LINES="$(ask "make lines to append to the product makefile (blank = keep)" "$PRODUCT_EXTRA_LINES")"
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
      --rom)          ROM="${2:-}"; shift 2 ;;
      --release)      LUNCH_RELEASE="${2:-}"; shift 2 ;;
      -d|--devices)   REQUESTED="${2:-}"; shift 2 ;;
      -u|--upload)
        DO_UPLOAD="yes"; shift
        if [[ "${1:-}" == "yes" || "${1:-}" == "no" ]]; then DO_UPLOAD="$1"; shift; fi
        ;;
      --no-upload)    DO_UPLOAD="no"; shift ;;
      --gh)
        DO_GH="yes"; shift
        if [[ "${1:-}" == "yes" || "${1:-}" == "no" ]]; then DO_GH="$1"; shift; fi
        ;;
      --no-gh)        DO_GH="no"; shift ;;
      --sf)
        DO_SF="yes"; shift
        if [[ "${1:-}" == "yes" || "${1:-}" == "no" ]]; then DO_SF="$1"; shift; fi
        ;;
      --no-sf)        DO_SF="no"; shift ;;
      --gh-repo)      GH_RELEASE_REPO="${2:-}"; shift 2 ;;
      --sf-folder)    SF_FOLDER="${2:-}"; shift 2 ;;
      --mirror)       IFS=',' read -ra _m <<<"${2:-}"; MIRROR_URLS+=("${_m[@]}"); shift 2 ;;
      --codename)     MIRROR_CODENAME="${2:-}"; shift 2 ;;
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
      --revert-patches) REVERT_PATCHES="yes"; shift ;;
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
      short="${DEVICES[$i]%%|*}"; short="${short#$ROM_PREFIX}"
      if [[ "$w" == "$short" || "$w" == "$((i + 1))" ]]; then
        SELECTED+=("${DEVICES[$i]}")
      fi
    done
  done
  [[ ${#SELECTED[@]} -gt 0 ]] || die "no devices matched '$req'"
}

on_interrupt() {
  local r="${ANDROID_ROOT:-}" a
  trap - INT TERM HUP
  if [[ -n "$INJECTED_MK" ]]; then
    restore_product_lines "$INJECTED_MK"
    say "   product makefile restored: ${INJECTED_MK#$r/}"
  fi
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

# --mirror URL[,URL...]: no build - fetch files straight from a Buzzheavier (or
# any) link and publish them to the enabled mirrors.  The codename is read from
# the file's own name (boot/vendor_boot/zip keep their tag), or forced with
# --codename NAME.
mirror_links() {
  local dir="$RELEASE_ROOT/mirror/$(date -u +%Y%m%d-%H%M%S)" u name tag rc=0
  [[ "$DO_GH" == "yes" || "$DO_SF" == "yes" ]] \
    || die "--mirror needs a destination: add --gh and/or --sf"
  mkdir -p "$dir" || return 1
  for u in "${MIRROR_URLS[@]}"; do
    [[ -n "$u" ]] || continue
    if [[ "$DRY_RUN" == "yes" ]]; then
      name="$(basename "${u%%\?*}")"
      tag="$MIRROR_CODENAME"; [[ -n "$tag" ]] || tag="$(codename_of "$name")"
      say "    curl -fL -o $dir/$name $u   (codename ${tag:-?})"
      publish_file "$dir/$name" "$name" "$tag" "tranG81 mirror $name" || rc=1
      continue
    fi
    name="$(curl -fsSL -D - -o /dev/null "$u" 2>/dev/null \
            | sed -n 's/.*[Ff]ilename="*\([^";]*\)"*.*/\1/p' | tail -n1)"
    [[ -n "$name" ]] || name="$(basename "${u%%\?*}")"
    [[ -n "$name" ]] || { err "cannot tell a file name from $u"; rc=1; continue; }
    tag="$MIRROR_CODENAME"; [[ -n "$tag" ]] || tag="$(codename_of "$name")"
    info "fetching $u -> $name (codename ${tag:-?})"
    curl -fsSL -o "$dir/$name" "$u" || { err "download failed: $u"; rc=1; continue; }
    if [[ -z "$tag" ]]; then
      err "cannot tell the codename of $name - pass --codename NAME"
      rc=1; continue
    fi
    publish_file "$dir/$name" "$name" "$tag" "tranG81 mirror $name" || rc=1
  done
  return "$rc"
}

main() {
  parse_args "$@"
  apply_rom
  [[ -z "$NOTIFY_MODE" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] && NOTIFY_MODE="telegram"
  need curl; need sha1sum; need sha256sum; need base64
  if [[ "$DO_GH" == "yes" ]] && ! have gh; then
    warn "github: gh CLI not found - GitHub release skipped"
    DO_GH="no"
  fi
  if [[ "$DO_SF" == "yes" ]] && { ! have ssh || ! have rsync; }; then
    warn "sourceforge: ssh/rsync not found - SourceForge skipped"
    DO_SF="no"
  fi
  find_root
  # what GApps/microG the tree actually provides, then the matching menu
  rom_prepare

  if [[ ${#MIRROR_URLS[@]} -gt 0 ]]; then
    RELEASE_ROOT="$ANDROID_ROOT/out/tranG81-releases"
    mkdir -p "$RELEASE_ROOT"
    if [[ "$DO_SF" == "yes" && -z "$SF_FOLDER" && -t 0 && -r /dev/tty ]]; then
      sf_pick_folder || DO_SF="no"
    fi
    if ! mirror_links; then err "some files were not published"; exit 1; fi
    if [[ ${#MIRROR_LINKS[@]} -gt 0 ]]; then
      info "published:"
      for a in "${MIRROR_LINKS[@]}"; do say "   $a"; done
    fi
    exit 0
  fi

  if [[ -z "$VARIANT" && "$REVERT_PATCHES" != "yes" ]]; then
    [[ -t 0 ]] || die "no variant given - use -v user|userdebug|eng"
    interactive_menu
  fi
  if [[ "$REVERT_PATCHES" != "yes" ]]; then
    case "$VARIANT" in
      user|userdebug|eng) ;;
      *) die "bad variant: $VARIANT (user|userdebug|eng)" ;;
    esac
  fi
  [[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] || { warn "--min-free/MIN_FREE_GB is not a number - using 40"; MIN_FREE_GB=40; }

  if [[ "$DO_SF" == "yes" && -z "$SF_FOLDER" ]]; then
    if [[ -t 0 && -r /dev/tty ]]; then sf_pick_folder || DO_SF="no"
    else warn "sourceforge: no --sf-folder given - SourceForge skipped"; DO_SF="no"; fi
  fi

  select_devices "$REQUESTED"

  if [[ "$REVERT_PATCHES" == "yes" ]]; then
    revert_selected_patches && info "done - tree patches reverted" \
      || warn "some patches could not be reverted (see above)"
    exit 0
  fi

  # fold --gms/env into the fixed vanilla -> gapps -> microg build order.
  [[ ${#GMS_WANT[@]} -gt 0 ]] || GMS_WANT=("$GMS_MODES")
  normalize_gms "${GMS_WANT[@]+"${GMS_WANT[@]}"}"

  RELEASE_ROOT="$ANDROID_ROOT/out/tranG81-releases"
  LOG_DIR="$ANDROID_ROOT/out/tranG81-logs"
  mkdir -p "$RELEASE_ROOT/$VARIANT" "$LOG_DIR"

  setup_ccache

  local first_product="${SELECTED[0]%%|*}"
  LUNCH_RELEASE="$(resolve_release "$first_product")"
  if [[ "$ROM_LUNCH_STYLE" == "release" && -z "$LUNCH_RELEASE" ]]; then
    die "could not determine a lunch release - pass --release NAME"
  fi

  say "======================================================================"
  info "rom      : $ROM_NAME ($ROM)"
  info "variant  : $VARIANT"
  [[ -n "$LUNCH_RELEASE" ]] && info "release  : $LUNCH_RELEASE"
  info "build    : $ROM_SETUP_CMD + $(rom_build_args | tr '\n' ' ' | sed 's/ *$//')"
  info "root     : $ANDROID_ROOT"
  if [[ "$DO_UPLOAD" == "yes" ]]; then
    info "upload   : yes $([[ -n "$BUZZ_ACCOUNT_ID" ]] && echo "(account)" || echo "(anonymous)")"
  else
    info "upload   : no"
  fi
  [[ "$DO_GH" == "yes" ]] && info "github   : $GH_RELEASE_REPO (one release per codename)"
  [[ "$DO_SF" == "yes" ]] && info "sf       : $SF_PROJECT/$SF_FOLDER (frs.sourceforge.net)"
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

  trap on_interrupt INT TERM HUP
  RUN_START=$(date +%s)

  local entry product devtree vendortree device sysdev radiodir fp nfc log a name rzip tag
  local idx=0 total=${#SELECTED[@]} t0 dt status mode
  local -a pf

  for entry in "${SELECTED[@]}"; do
    idx=$((idx + 1))
    IFS='|' read -r product devtree vendortree device sysdev radiodir fp <<<"$entry"
    nfc=0; [[ "$product" == "${ROM_PREFIX}KL5n" ]] && nfc=1

    # all GMS modes of one device run together, before the next device; KL5n
    # patches the shared hardware/nxp/nfc HAL and never reverts it, so it must
    # be the very last device to build.
    for mode in "${GMS_MODE_LIST[@]}"; do
    GMS_MODE="$mode"
    RELEASE_MODE_DIR="$RELEASE_ROOT/$VARIANT/$mode"
    mkdir -p "$RELEASE_MODE_DIR"

    say ""
    info "=== $product  [$idx/$total]  [$mode]  (device=$device system=$sysdev) ==="

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
      [[ "$DO_GH" == "yes" || "$DO_SF" == "yes" ]] && \
        say "    -> mirror each to$([[ "$DO_GH" == yes ]] && printf ' github (%s)' "$GH_RELEASE_REPO")$([[ "$DO_SF" == yes ]] && printf ' sourceforge (%s/%s)' "$SF_PROJECT" "$SF_FOLDER")"
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
      rm -f "$ANDROID_ROOT"/out/target/product/"$device"/$ROM_ZIP_GLOB
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
      rzip=$(ls -1t "$ANDROID_ROOT/out/target/product/$device"/$ROM_ZIP_GLOB 2>/dev/null | head -n1)
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

    if [[ "$DO_GH" == "yes" || "$DO_SF" == "yes" ]]; then
      tag="${product#$ROM_PREFIX}"
      for a in "${COLLECTED[@]}"; do
        name="$(basename "$a")"
        publish_file "$a" "$name" "$tag" \
          "tranG81 $product $GMS_MODE $VARIANT $sysdev $(date -u +%Y-%m-%dT%H:%MZ)" \
          || { warn "$product: mirror failed for $name"; FAILED+=("$product [$GMS_MODE] (mirror $name)"); status=failed; }
      done
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

  if [[ ${#LINKS[@]} -gt 0 || ${#MIRROR_LINKS[@]} -gt 0 ]]; then
    local lf="$RELEASE_ROOT/links-$VARIANT-$(date -u +%Y%m%d-%H%M%S).txt"
    [[ ${#LINKS[@]} -gt 0 ]]        && { info "links:";   for a in "${LINKS[@]}"; do say "   $a"; done; }
    [[ ${#MIRROR_LINKS[@]} -gt 0 ]] && { info "mirrors:"; for a in "${MIRROR_LINKS[@]}"; do say "   $a"; done; }
    { [[ ${#LINKS[@]} -gt 0 ]] && printf '%s\n' "${LINKS[@]}"
      [[ ${#MIRROR_LINKS[@]} -gt 0 ]] && printf '%s\n' "${MIRROR_LINKS[@]}"; } > "$lf"
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

  info "total: $(human_time $(( $(date +%s) - RUN_START )))   uploaded: $UPLOADED$([[ "$DO_GH" == yes ]] && printf '   github: %s' "$GH_UPLOADED")$([[ "$DO_SF" == yes ]] && printf '   sourceforge: %s' "$SF_UPLOADED")"

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
