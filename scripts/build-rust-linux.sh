#!/usr/bin/env bash
# Build the Rust scheduling core as a Linux x86_64 cdylib and put it where
# both `flutter run`/`flutter test` (flutter_rust_bridge's ioDirectory) and a
# packaged Linux release (bundle/lib via linux/CMakeLists.txt) can load it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for tool in cargo rustc; do
  command -v "$tool" >/dev/null || {
    echo "$tool is required (install the Rust toolchain via rustup)." >&2
    exit 1
  }
done

HOST_TRIPLE="$(rustc -vV | awk '/^host:/ {print $2}')"
if [[ "$HOST_TRIPLE" != "x86_64-unknown-linux-gnu" ]]; then
  echo "This script targets Linux x86_64; current host is $HOST_TRIPLE." >&2
  echo "Cross-compiling needs a matching x86_64-linux linker/sysroot; refusing" >&2
  echo "to place a wrong-architecture .so where the loader would trust it." >&2
  exit 1
fi

cd "$ROOT/rust/scheduler"
cargo build --release

SO="$ROOT/rust/scheduler/target/release/libscheduler.so"
if [[ ! -f "$SO" ]]; then
  echo "cargo finished but $SO is missing (check crate-type in Cargo.toml)." >&2
  exit 1
fi

echo "Built: $SO"
file "$SO" || true

# Two load paths are now satisfied:
#   * flutter run / flutter test: CWD is the repo root, so
#     rust/scheduler/target/release/libscheduler.so is found directly.
#   * packaged release: linux/CMakeLists.txt installs this same file into
#     bundle/lib, resolved by the executable's \$ORIGIN/lib rpath.
# If the Rust FFI surface changes, regenerate the Dart bridge with
# flutter_rust_bridge_codegen (frb_generated.dart holds the content hash).
