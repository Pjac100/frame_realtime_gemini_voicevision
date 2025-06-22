#!/usr/bin/env bash
# Usage: install_flutter.sh <flutter_version>
set -euo pipefail
VERSION="${1:-3.24.0}"

echo "▶ Installing Flutter $VERSION …"
git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$HOME/flutter"
( cd "$HOME/flutter" && git checkout "refs/tags/$VERSION" )

echo 'export PATH="$HOME/flutter/bin:$PATH"' >> "$HOME/.zshrc"
"$HOME/flutter/bin/flutter" --version
