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
# the "github release" / "sourceforge" rows toggle those mirrors and the
# "sf folder" row (space/enter) opens the SourceForge folder picker; the
# "no build - links" row opens a paste box: paste the whole download-links
# block (the file names come from the block) and it publishes them to the
# enabled mirrors, grouped per codename, no build.
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
# vanilla -> gapps -> microg (microG last), all of a device's modes before the
# next device.  vanilla is stock LineageOS; gapps
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

# also publish to GitHub Releases and/or SourceForge (Buzzheavier stays on -u)
# --gh -> one release per codename (tag and name = X6531/X6531B/X6532/KL5/KL5n)
#        in GH_RELEASE_REPO (default Transsion-G81/release).  The rom zip and
#        the tagged boot/vendor_boot images are replaced on every run, so a
#        rebuild across ROMs/GMS modes lands in the same release.  gh
#        authenticates itself (GH_TOKEN/GITHUB_TOKEN or `gh auth login`); with
#        no gh CLI, or a login that cannot write the repo (a 404 on an org repo
#        usually means no access, not a wrong name), github is skipped with a
#        warning and the other mirrors still run.
# --sf -> rsync the same files over your SSH key to
#        frs.sourceforge.net:/home/frs/project/<SF_PROJECT>/<SF_FOLDER>/<codename>/
#        SF_PROJECT defaults to naze-release (https://sourceforge.net/projects/naze-release/);
#        SF_FOLDER is asked once like a small file manager: a number (or a
#        typed name) opens - and, if new, creates - that subfolder, "b" goes
#        back up and "n" (or Enter) uses the current folder.  The result is a
#        path (e.g. cusrom/releases); pass
#        --sf-folder NAME to skip the prompt.  SF_USER is
#        your SourceForge login (default nazephyrus); override with --sf-user
#        NAME / SF_USER.  The FRS login is a copy-only shell, so folders are
#        listed/created over sftp and files sent with rsync; both run in
#        BatchMode, so set up your SourceForge SSH key first (see --setup).

# set the account/project/folder once and forget the flags: --setup makes an
# SSH keypair (~/.ssh/id_ed25519) if you have none and prints the public key to
# paste at https://sourceforge.net/auth/shell_services (Me -> Account -> SSH
# Settings), tests the connection, and saves the GitHub repo + SourceForge
# login/project/folder to $HOME/.config/build-all/config (override with
# BUILD_ALL_CONFIG); every later run reads it.  Environment values or flags
# still win over the file.
./build-all.sh --setup
./build-all.sh -v user -u yes --gh --sf
./build-all.sh -v user --gh --sf --sf-project naze-release --sf-folder releases --gh-repo Transsion-G81/release

# no build: publish files from a past Buzzheavier (or any) link.  paste a whole
# download-links block and each URL takes the file name of the label line above
# it (a bare URL list falls back to the name in the link); the codename is read
# from the file name (override with --codename NAME) and the files are grouped
# per codename.  a file still in the release dir, the build output, or a
# BUILD_ALL_ARTIFACTS (colon-separated) dir is reused, else downloaded.  a
# Buzzheavier link is resolved through curl_cffi, since its page + /download
# route answer only a Chrome TLS fingerprint; the resolver is installed once
# into BUZZ_PY_LIB (default ~/.local/share/build-all/pylibs) if the system
# python lacks it, then the signed CDN link it returns is fetched with plain
# curl.  same as the TUI "no build - links" row.
./build-all.sh --mirror https://buzzheavier.com/<id>,https://buzzheavier.com/<id2> --gh --sf --sf-folder releases
# ...or point the reuse search at the dir holding your build outputs
BUILD_ALL_ARTIFACTS="/srv/builds/tranG81-releases" ./build-all.sh --mirror <block pasted> --gh --sf

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
# then "ax -b", so its GMS choice is the gms arg (vanilla or gms).  Axion has no
# microG flavor upstream, so its microG pass configures vanilla and turns on the
# gate our device tree reads - unofficial, may not build or boot.
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
