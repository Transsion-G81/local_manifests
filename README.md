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
# device / the upload switch / the xgsi switch, left/right picks the variant,
# a/n select all/none devices, x toggles xgsi, enter starts, q quits.
# nothing has to be installed - no dialog, whiptail or fzf.  without a
# terminal (or with stdin piped) it falls back to the plain numbered prompts.

# non-interactive: -v user|userdebug|eng, -u [yes|no] to upload
./build-all.sh -v userdebug -u yes

# xgsi boot/dmesg log capture (the "xgsi boot/dmesg logs" checkbox in the
# menu, or this env var - exactly "true").  device.mk reads it at
# product-config time, so clear out/target/product/<device> once if the tree
# already built, or the copied log scripts may not land in the rom
WITH_XGSI_LOGS=true ./build-all.sh -v userdebug -u yes

# status ping when the run ends - Telegram:
#   1) create a bot with @BotFather and copy the token
#   2) send the bot a message, then read your chat id from
#      https://api.telegram.org/bot<TOKEN>/getUpdates
./build-all.sh -v userdebug -u yes --notify telegram:<TOKEN>:<CHAT_ID>

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

# LineageOS 23.x lunch wants a release config; the script reads it from
# vendor/lineage/vars/aosp_target_release (e.g. bp4a) and you can override it:
./build-all.sh -v userdebug --release bp4a

# all options
./build-all.sh --help

# outputs (under out/)
#   out/tranG81-releases/<variant>/   zips + tagged images, links-<variant>-<ts>.txt, releases-<variant>.json
#   out/tranG81-logs/<product>-<variant>.log
```
