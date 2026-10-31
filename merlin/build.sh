#!/bin/sh
# Cross-compile honk-core for the RT-BE88U (aarch64 musl, no eBPF) and pack
# the addon: binary, scripts, page, zashboard, and geo databases.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if ! command -v zig >/dev/null 2>&1; then
    echo "merlin/build.sh: install zig 0.14.1" >&2
    exit 1
fi
if ! command -v cmake >/dev/null 2>&1; then
    echo "merlin/build.sh: install cmake (boring-sys)" >&2
    exit 1
fi

rustup target add aarch64-unknown-linux-musl
T=aarch64-unknown-linux-musl
export ZIGCC_TARGET=aarch64-linux-musl
L=$(printf '%s' "$T" | tr '-' '_')
U=$(printf '%s' "$T" | tr 'a-z-' 'A-Z_')
eval "export CC_${L}=\$root/ci/zigcc"
eval "export CXX_${L}=\$root/ci/zigcxx"
eval "export CARGO_TARGET_${U}_LINKER=\$root/ci/zigcc"
eval "export CARGO_TARGET_${U}_RUSTFLAGS='-C link-self-contained=no'"
BINDGEN_EXTRA_CLANG_ARGS="$(ci/zig-bindgen-env "$ZIGCC_TARGET")"
export BINDGEN_EXTRA_CLANG_ARGS
cargo build --release -p honk-core --no-default-features \
    --features clash-api,mimalloc,rprx,redirect \
    --target "$T"

bin=$root/target/$T/release/honk-core
file "$bin" | grep -q 'statically linked'
stage=$(mktemp -d)
mkdir -p "$stage/honk/scripts" "$stage/honk/www" "$stage/honk/ui"
cp "$bin" "$stage/honk/honk-core"
cp -R "$root/merlin/scripts/." "$stage/honk/scripts/"
cp -R "$root/merlin/www/." "$stage/honk/www/"
cp "$root/merlin/README_merlin.md" "$stage/honk/README_merlin.md"
python3 "$root/merlin/tools/fetch-assets.py" "$stage/honk"
chmod 755 "$stage/honk/honk-core" "$stage/honk/scripts/"*.sh
mkdir -p "$root/merlin/dist"
tar -C "$stage" -czf "$root/merlin/dist/honk-be88u.tar.gz" honk
rm -rf "$stage"
echo "wrote $root/merlin/dist/honk-be88u.tar.gz"
