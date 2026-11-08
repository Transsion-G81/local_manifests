# how to use
```bash
# make folder
mkdir -p .repo/local_manifests

# curl
curl -L https://raw.githubusercontent.com/Transsion-G81/local_manifests/refs/heads/main/local_manifest.xml > .repo/local_manifests/mt6768_manifest.xml

# sync
repo sync -c --force-sync --no-clone-bundle --no-tags
```

# how to build + upload
```bash
# get the script
curl -L https://raw.githubusercontent.com/Transsion-G81/local_manifests/refs/heads/main/build-all.sh > build-all.sh
chmod +x build-all.sh

# run it from the root of the source tree (or set ANDROID_ROOT)
# builds X6531, X6531B, X6532, KL5, KL5n in that order, sha1-checks each
# product firmware before building, then collects the rom zip + boot.img +
# vendor_boot.img and uploads them to buzzheavier (each upload is
# sha256-verified against the hash the service reports)
./build-all.sh

# the menu is a pure-bash full-screen TUI: up/down move, space toggles a
# device / the upload switch / the xgsi switch / the gms row, left/right picks
# the rom / the variant / the gms set, a/n select all/none devices, x toggles
# xgsi, g cycles the gms set, e (or enter on the "make lines" row) edits the
# extra make lines, r reverts our tree patches and stops, enter starts, q quits.
# the "rom" row reloads the picked profile's devices and gms menu, so every
# profile (including axion) can be built from the menu alone - same as --rom.
# nothing has to be installed - no dialog, whiptail or fzf.  without a
# terminal (or with stdin piped) it falls back to the plain numbered prompts.

# non-interactive: -v user|userdebug|eng, -u [yes|no] to upload
./build-all.sh -v userdebug -u yes

# xgsi boot/dmesg log capture (the "xgsi boot/dmesg logs" checkbox in the
# menu, or this env var - exactly "true").  device.mk reads it at
# product-config time, so clear out/target/product/<device> once if the tree
# already built, or the copied log scripts may not land in the rom
WITH_XGSI_LOGS=true ./build-all.sh -v userdebug -u yes

# GMS variants: every device is built once per mode, in the fixed order
# vanilla -> gapps -> microg (microG last).  vanilla is stock LineageOS; gapps
# bakes MindTheGapps (vendor/gapps); microg bakes microG (vendor/partner_gms,
# LineageOS already ships microG-only signature spoofing).  Each mode builds
# only its own pass, so "gapps" alone does not build vanilla first - pick a
# combo to build several in one run.  gapps and microG are mutually exclusive.
./build-all.sh -v user -u yes --gms gapps          # gapps only
./build-all.sh -v user -u yes --gms microg         # microG only
./build-all.sh -v user -u yes --gms vanilla+gapps  # vanilla + gapps
./build-all.sh -v user -u yes --gms all            # vanilla + gapps + microG
# --gapps / --microg are shorthands for --gms gapps / --gms microg; the menu's
# gms row offers the same set (vanilla / gapps / microg / vanilla+gapps / all).
# gapps/microG are read from device.mk at product-config time, so the product
# out dir is cleared whenever the mode changes (a per-product .trang81-gms
# stamp tracks it) - no need to clean by hand.  GMS_MODES also works (comma
# list or "all"); the mode is echoed in the TUI, the log name, the JSON and the
# Telegram ping.
# microG's tree gets a Soong namespace so its GmsCore doesn't clash with gapps'
# GmsCore; build-all.sh drops vendor/partner_gms/Android.bp and device.mk exports it.
#
# status ping when the run ends - Telegram:
#   1) create a bot with @BotFather and copy the token
#   2) send the bot a message, then read your chat id from
#      https://api.telegram.org/bot<TOKEN>/getUpdates
./build-all.sh -v userdebug -u yes --notify telegram:<TOKEN>:<CHAT_ID>

# on success it also posts the download link of every uploaded file, grouped
# per device and tagged rom / boot / vendor_boot / image
# on a build failure the error tail is posted and the full build log is
# uploaded to the chat as a file
# ...or export them once and Telegram notify turns itself on
export TELEGRAM_BOT_TOKEN=<TOKEN> TELEGRAM_CHAT_ID=<CHAT_ID>
./build-all.sh -v userdebug -u yes

# a plain webhook URL still posts the Discord/Slack payload
./build-all.sh --notify https://discord.com/api/webhooks/...

# sign in to buzzheavier for longer-lived links (anonymous links expire in a
# few days; the expiry is printed for every upload)
./build-all.sh -v userdebug -u yes -a <account_id>

# bigger/faster: ccache, explicit jobs, extra image (dtbo)
CCACHE_SIZE=50G ./build-all.sh -v userdebug -u yes --jobs 16
EXTRA_IMAGES="boot.img vendor_boot.img dtbo.img" ./build-all.sh -v userdebug -u yes

# re-upload what a previous run already collected, without rebuilding
./build-all.sh -v userdebug -u yes --no-build

# safety / checks
./build-all.sh --check-only      # firmware + tree checks only, no build
./build-all.sh --dry-run         # print the plan, touch nothing
./build-all.sh --min-free 60     # refuse to start below 60G free

# reverse-apply the patches our device trees drop into the source (X6532 ->
# frameworks/base SystemUI, KL5 -> hardware/nxp/nfc), for the selected devices,
# then stop.  Maintenance only: a later build re-applies them through
# envsetup.sh unless you set PATCH_SHADE=0 (SystemUI) / leave PATCH_NFC unset.
./build-all.sh --revert-patches                  # all devices
./build-all.sh --revert-patches -d X6532,KL5n    # just these

# LineageOS 23.x lunch wants a release config; the script reads it from
# vendor/lineage/vars/aosp_target_release (e.g. bp4a) and you can override it:
./build-all.sh -v userdebug --release bp4a

# custom ROM profile: --rom lineage (default), evox, yaap, infinity or axion
# each profile carries the ROM's own build entry points: lineage/evox/yaap/
# infinity use lunch + mka; axion runs its "axion <codename> <variant> <gms>"
# then "ax -b", so its GMS choice is the gms arg (vanilla or gms)
./build-all.sh --rom axion -v user -u yes

# some ROMs want extra make lines at the very bottom of
# device/<tree>/lineage_<device>.mk; the script appends them for the build and
# takes them off again, so the shared tree stays clean (axion already injects
# TARGET_DISABLE_EPPE; add the AXION_* device-info lines this way, or through
# the TUI's "make lines" row).  A line the tree already carries is not
# duplicated, and the build stops if a line cannot be placed:
PRODUCT_EXTRA_LINES="AXION_PROCESSOR := MediaTek_Helio_G81" ./build-all.sh --rom axion -v user
# per device: PRODUCT_EXTRA_LINES_X6532="AXION_CAMERA_REAR_INFO := 50,48"

# all options
./build-all.sh --help

# outputs (under out/)
#   out/tranG81-releases/<variant>/<mode>/   rom zip (non-vanilla ones get a
#       -GAPPS/-MICROG suffix) + tagged boot/vendor_boot images
#   out/tranG81-releases/links-<variant>-<ts>.txt    every upload link
#   out/tranG81-releases/releases-<variant>.json     one record per device+mode
#   out/tranG81-logs/<product>-<variant>-<mode>.log
```
