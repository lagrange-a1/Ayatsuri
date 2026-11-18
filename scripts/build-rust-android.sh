#!/usr/bin/env bash
# Build the Rust scheduling core as Android JNI libraries and place them where
# Gradle/Flutter packages them automatically (jniLibs/<abi>/libscheduler.so).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  if [[ -n "${ANDROID_NDK_LATEST_HOME:-}" ]]; then
    export ANDROID_NDK_HOME="$ANDROID_NDK_LATEST_HOME"
  elif [[ -d /opt/android-ndk ]]; then
    export ANDROID_NDK_HOME=/opt/android-ndk
  else
    echo "ANDROID_NDK_HOME is not set and no NDK was found." >&2
    exit 1
  fi
fi

command -v cargo-ndk >/dev/null || {
  echo "cargo-ndk is required: cargo install cargo-ndk --locked" >&2
  exit 1
}

mkdir -p "$ROOT/android/app/src/main/jniLibs"
cd "$ROOT/rust/scheduler"
cargo ndk \
  -t armeabi-v7a \
  -t arm64-v8a \
  -t x86_64 \
  -o "$ROOT/android/app/src/main/jniLibs" \
  build --release

find "$ROOT/android/app/src/main/jniLibs" -name 'libscheduler.so' -exec ls -lh {} \;
