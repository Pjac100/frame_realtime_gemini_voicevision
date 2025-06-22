#!/usr/bin/env bash
set -euo pipefail

# Exact Flutter release your CI job reported (rev 6fba2447e9)
FLUTTER_VERSION="3.32.4"
SDK_DIR="$HOME/flutter"

if [[ ! -d "$SDK_DIR" ]]; then
  echo "📦  Installing Flutter $FLUTTER_VERSION ..."
  curl -sL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    | tar -xJ -C "$HOME"
fi

# Persist PATH for every shell in this Codespace
if ! grep -q 'flutter/bin' ~/.bashrc; then
  echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc
fi

# Pre-warm toolchain (so the first build inside Codespace is fast)
flutter --version
flutter doctor -v

