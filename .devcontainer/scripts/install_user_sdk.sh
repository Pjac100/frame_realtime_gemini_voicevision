#!/usr/bin/env bash
# Usage: install_user_sdk.sh <build-tools> <platform33> <platform31> <platform29> <ndk>
set -euo pipefail

BUILD_TOOLS=${1:-33.0.1}
P33=${2:-33}
P31=${3:-31}
P29=${4:-29}
NDK_VER=${5:-26.3.11579264}

SDK_ROOT="$HOME/android-sdk"
mkdir -p "$SDK_ROOT"

echo "▶ Installing Android SDK into $SDK_ROOT …"
yes | sdkmanager --sdk_root="$SDK_ROOT" \
  "platform-tools" \
  "platforms;android-$P33" \
  "platforms;android-$P31" \
  "platforms;android-$P29" \
  "build-tools;$BUILD_TOOLS" \
  "ndk;$NDK_VER"

yes | sdkmanager --licenses --sdk_root="$SDK_ROOT"

echo 'export ANDROID_SDK_ROOT=$HOME/android-sdk' >> "$HOME/.zshrc"
echo 'export PATH=$ANDROID_SDK_ROOT/platform-tools:$PATH' >> "$HOME/.zshrc"
