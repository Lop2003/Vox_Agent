#!/bin/sh
# Simulator-only workaround for Thai speech-to-text.
#
# Apple ships the on-device Thai speech model as a Cryptex, which the iOS Simulator can't mount.
# Once it downloads, recognition fails with "Failed to initialize recognizer". This removes the
# broken model and makes its folder read-only so it can't come back; the Speech framework then
# falls back to Apple's servers, which handle Thai fine. Real iPhones don't need this.
#
# Usage: scripts/sim-thai-stt.sh          apply to every simulator
#        scripts/sim-thai-stt.sh --undo   let simulators download models again
set -eu

found=0
for dir in "$HOME"/Library/Developer/CoreSimulator/Devices/*/data/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_UAF_Siri_Understanding/purpose_auto; do
    [ -d "$dir" ] || continue
    found=1
    chmod u+w "$dir"
    if [ "${1:-}" = "--undo" ]; then
        echo "restored: $dir"
        continue
    fi
    for asset in "$dir"/*.asset; do
        if [ -f "$asset/Info.plist" ] && grep -q "asr.assistant.th_TH" "$asset/Info.plist"; then
            rm -rf "$asset"
            echo "removed broken Thai model: $asset"
        fi
    done
    chmod a-w "$dir"
done

[ "$found" = 1 ] || { echo "No simulator speech assets found (use Thai speech in the simulator once first)."; exit 0; }

# Make the simulator's speech service forget the old model; launchd restarts it on demand.
pkill -f "CoreSimulator.*localspeechrecognition" 2>/dev/null || true
echo "Done. Relaunch Vox Agent in the simulator."
