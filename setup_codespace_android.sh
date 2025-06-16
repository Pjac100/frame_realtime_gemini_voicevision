#!/usr/bin/env bash
# One-shot generator for an Android (and optional Flutter) GitHub Codespace.
# Run from the root of your repo:  bash setup_codespace_android.sh [--flutter]

set -euo pipefail

# ───────────── Options ─────────────
JDK_VERSION=17
ANDROID_SDK_VERSION=34.0.0   # API 34 by default
FLUTTER=false

for arg in "$@"; do
  case "$arg" in
    --flutter) FLUTTER=true ;;
    --jdk-version=*)       JDK_VERSION="${arg#*=}" ;;
    --android-sdk-version=*) ANDROID_SDK_VERSION="${arg#*=}" ;;
    -h|--help)
      echo "Usage: $0 [--flutter] [--jdk-version=N] [--android-sdk-version=N]"
      exit 0 ;;
    *) echo "❌ Unknown option: $arg"; exit 1 ;;
  esac
done

echo "📦  Creating .devcontainer layout…"
mkdir -p .devcontainer/scripts

# ───────────── accept-licences helper ─────────────
cat > .devcontainer/scripts/accept-android-licenses.sh <<'EOS'
#!/usr/bin/env bash
set -e
yes | ${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager --licenses
EOS
chmod +x .devcontainer/scripts/accept-android-licenses.sh

# ───────────── Dockerfile ─────────────
cat > .devcontainer/Dockerfile <<'EOS'
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        unzip git-lfs zlib1g-dev libgl1-mesa-dev curl wget && \
    rm -rf /var/lib/apt/lists/*

ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=\$PATH:\$ANDROID_HOME/emulator:\$ANDROID_HOME/platform-tools
EOS

# ───────────── devcontainer.json ─────────────
cat > .devcontainer/devcontainer.json <<EOF
{
  "name": "android-codespace",
  "build": { "dockerfile": "Dockerfile" },
  "features": {
    "ghcr.io/devcontainers/features/java:1":  { "version": "${JDK_VERSION}" },
    "ghcr.io/casl0/devcontainer-features/android-sdk:1": { "version": "${ANDROID_SDK_VERSION}" },
    "ghcr.io/devcontainers/features/gradle:1": {}
  },
  "postCreateCommand": [
    "./scripts/accept-android-licenses.sh",
    "./gradlew --version"
  ],
  "customizations": {
    "vscode": {
      "extensions": [
        "vscjava.vscode-gradle",
        "eamodio.gitlens",
        "ms-vscode.cpptools"
        $(if $FLUTTER; then printf ',\n        "dart-code.flutter"'; fi)
      ]
    }
  },
  "forwardPorts": [5555, 8080],
  "remoteUser": "codespace"
}
EOF

# ───────────── Flutter toggle ─────────────
if $FLUTTER; then
  # inject the Flutter feature line just before the closing brace
  sed -i '/"ghcr.io.devcontainers.features.gradle/ a\    ,"ghcr.io/hsun1031/devcontainer_flutter:latest": {}' .devcontainer/devcontainer.json
fi

echo "✅  All set!  Commit the new .devcontainer/ directory and click"
echo "   “Code ▸ Codespaces ▸ New Codespace” in GitHub."
if $FLUTTER; then
  echo "ℹ️  Flutter SDK will download on first build; hot reload works via 'flutter run -d chrome' or a physical device over ADB."
fi
