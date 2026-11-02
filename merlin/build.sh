#!/bin/sh
# Cross-compile honk-core for the RT-BE88U (aarch64 musl, no eBPF) and pack
# the addon: binary, scripts, page, pinned doona, and cn/private geo.
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
eval "export AR_${L}=\$root/ci/zigar"
eval "export RANLIB_${L}=\$root/ci/zigranlib"
eval "export CARGO_TARGET_${U}_LINKER=\$root/ci/zigcc"
eval "export CARGO_TARGET_${U}_RUSTFLAGS='-C link-self-contained=no'"
# cmake (boring-sys) and cc-rs both fall back to host ar/ranlib when unset.
# On macOS those write empty Darwin archives for ELF objects.
export AR="$root/ci/zigar"
export RANLIB="$root/ci/zigranlib"
export CMAKE_AR="$root/ci/zigar"
export CMAKE_RANLIB="$root/ci/zigranlib"
# cmake ignores CMAKE_AR as an env var and find_program()s `ar` on PATH.
export PATH="$root/ci/host-bin:$PATH"
export CMAKE_ARGS="-DCMAKE_AR=$root/ci/zigar -DCMAKE_RANLIB=$root/ci/zigranlib -DCMAKE_C_COMPILER_AR=$root/ci/zigar -DCMAKE_CXX_COMPILER_AR=$root/ci/zigar -DCMAKE_ASM_COMPILER_AR=$root/ci/zigar -DCMAKE_C_COMPILER_RANLIB=$root/ci/zigranlib -DCMAKE_CXX_COMPILER_RANLIB=$root/ci/zigranlib -DCMAKE_ASM_COMPILER_RANLIB=$root/ci/zigranlib"
BINDGEN_EXTRA_CLANG_ARGS="$(ci/zig-bindgen-env "$ZIGCC_TARGET")"
export BINDGEN_EXTRA_CLANG_ARGS
cargo build --release -p honk-core --no-default-features \
    --features native-api,mimalloc,redirect \
    --target "$T"

bin=$root/target/$T/release/honk-core
file "$bin" | grep -q 'statically linked'
# The installer prints this when the addon lands. Only merlin-v* tags count
# as addon versions; engine v* tags and the rolling merlin tag must not.
ver=$(git describe --tags --always --match 'merlin-v*' 2>/dev/null || echo dev)
stage=$(mktemp -d)
mkdir -p "$stage/honk/scripts" "$stage/honk/www"
cp "$bin" "$stage/honk/honk-core"
printf '%s\n' "$ver" >"$stage/honk/version"
cp "$root/merlin/scripts/"*.sh "$stage/honk/scripts/"
cp -R "$root/merlin/www/." "$stage/honk/www/"
cp "$root/merlin/README_merlin.md" "$stage/honk/README_merlin.md"
python3 "$root/merlin/tools/fetch-assets.py" "$stage/honk"
chmod 755 "$stage/honk/honk-core" "$stage/honk/scripts/"*.sh
mkdir -p "$root/merlin/dist"
# macOS tar otherwise injects AppleDouble `._*` members that waste /jffs.
COPYFILE_DISABLE=1 tar -C "$stage" -czf "$root/merlin/dist/honk-be88u.tar.gz" honk
rm -rf "$stage"
echo "wrote $root/merlin/dist/honk-be88u.tar.gz"
