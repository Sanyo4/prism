#!/usr/bin/env bash
# Prism — one-shot dev environment setup for Pop!_OS 24.04 / Ubuntu 24.04.
#
# What this installs (foundational, unblocks slices 1, 2, 4, 5, 7, 9):
#   - apt build deps (clang, cmake, ninja, libgtk-3-dev, liblzma-dev, ffmpeg, JDK 17, ...)
#   - Flutter stable (tarball into ~/development/flutter)
#   - Android cmdline-tools + platform-tools + Android 34 SDK + build-tools 34
#   - melos (Dart global)
#
# What this also installs (so slice 6 + slice 3 can start without re-prompting):
#   - Ollama daemon (no model pull — see footer)
#   - Python 3.11 + venv tooling (no Essentia install — see footer)
#
# Idempotent. Re-runnable. Will prompt once for sudo and once to accept Android licenses.
# Total disk: ~5 GB (Flutter ~1 GB, Android SDK ~3 GB, rest small).
# Total time: ~10 min on a decent connection (excluding the deferred 1.5 GB Ollama model pull).

set -euo pipefail

step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

step "Prism dev setup — Pop!_OS 24.04 / x86_64"
note "sudo password may be requested. Android license acceptance will be auto-yes'd."

# ── 1. apt: system build deps ────────────────────────────────────────────
step "[1/8] apt: build deps + Python + ffmpeg + JDK 17"
sudo apt update
sudo apt install -y \
  curl git unzip xz-utils ca-certificates \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libsqlite3-dev \
  python3 python3-venv python3-pip \
  ffmpeg openjdk-17-jdk

# ── 2. Flutter SDK (tarball) ─────────────────────────────────────────────
FLUTTER_DIR="$HOME/development/flutter"
if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  step "[2/8] Flutter: downloading current stable tarball"
  mkdir -p "$HOME/development"
  cd "$HOME/development"
  FLUTTER_URL=$(curl -sSL https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json \
    | python3 -c "import json,sys; d=json.load(sys.stdin); h=d['current_release']['stable']; r=next(r for r in d['releases'] if r['hash']==h); print(d['base_url']+'/'+r['archive'])")
  note "URL: $FLUTTER_URL"
  curl -L "$FLUTTER_URL" -o flutter.tar.xz
  tar xf flutter.tar.xz
  rm flutter.tar.xz
else
  step "[2/8] Flutter: already installed at $FLUTTER_DIR (skipping download)"
fi

# ── 3. PATH wiring (idempotent append to ~/.bashrc) ──────────────────────
if ! grep -q "# >>> prism dev env >>>" "$HOME/.bashrc" 2>/dev/null; then
  step "[3/8] PATH: appending Flutter / pub / Android SDK to ~/.bashrc"
  cat >> "$HOME/.bashrc" <<'EOF'

# >>> prism dev env >>>
export PATH="$HOME/development/flutter/bin:$PATH"
export PATH="$HOME/.pub-cache/bin:$PATH"
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
# <<< prism dev env <<<
EOF
else
  step "[3/8] PATH: already wired in ~/.bashrc (skipping)"
fi
# Apply to current shell so subsequent steps work
export PATH="$FLUTTER_DIR/bin:$HOME/.pub-cache/bin:$PATH"
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

# ── 4. Android cmdline-tools ─────────────────────────────────────────────
if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  step "[4/8] Android cmdline-tools: downloading"
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  cd /tmp
  curl -L https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip -o cmdline-tools.zip
  unzip -q -o cmdline-tools.zip -d "$ANDROID_HOME/cmdline-tools"
  # Google ships them in a folder called "cmdline-tools" — relocate to .../latest
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
  rm cmdline-tools.zip
else
  step "[4/8] Android cmdline-tools: already installed (skipping)"
fi

# ── 5. Android SDK packages + license acceptance ─────────────────────────
step "[5/8] Android SDK: platform-tools, Android 34 platform, build-tools 34"
# `yes |` triggers SIGPIPE on yes once sdkmanager closes stdin, which `set -o pipefail`
# would catch as a non-zero pipeline exit. Disable pipefail just for these license commands.
set +o pipefail
yes | sdkmanager --licenses >/dev/null
set -o pipefail
sdkmanager --install \
  "platform-tools" \
  "platforms;android-34" \
  "build-tools;34.0.0"

# ── 6. Flutter config + license sweep + precache ─────────────────────────
step "[6/8] Flutter: config + Android licenses + precache (linux + android)"
flutter config --android-sdk "$ANDROID_HOME" >/dev/null
flutter config --enable-linux-desktop >/dev/null
set +o pipefail
yes | flutter doctor --android-licenses >/dev/null
set -o pipefail
flutter precache --linux --android

# ── 7. Melos ─────────────────────────────────────────────────────────────
step "[7/8] Dart: activating melos globally"
dart pub global activate melos

# ── 8. Ollama daemon (slice 6) ───────────────────────────────────────────
if ! command -v ollama >/dev/null; then
  step "[8/8] Ollama: installing daemon (model pull deferred)"
  curl -fsSL https://ollama.com/install.sh | sh
else
  step "[8/8] Ollama: already installed (skipping)"
fi

# ── Final report ─────────────────────────────────────────────────────────
echo
step "Done."
echo
note "Open a new shell (or 'source ~/.bashrc') so PATH changes take effect, then:"
note "  flutter doctor -v        # should be all green except 'Connected device' until you plug the Pixel"
echo
note "Per-slice add-ons NOT installed by this script (do these inside the matching slice's session):"
note "  • slice 3 (Essentia indexer): create a venv in apps/indexer/, pip install essentia-tensorflow + click."
note "  • slice 6 (desktop LLM): ollama serve & ; ollama pull qwen3:1.7b   # ~1.5 GB"
note "  • slice 8 (Android LLM): Cactus weights download from inside the running Android app."
note "  • slice 9 (cast/DLNA): nothing — uses pure-Dart shelf + native UPnP."
echo
note "Phone setup (one-time, manual): on your Pixel 9 Pro Fold, enable Developer options + USB debugging,"
note "then connect via USB and run:  adb devices   # should list the serial."
