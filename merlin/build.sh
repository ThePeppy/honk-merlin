#!/bin/sh
# Cross-compile the phase-1 dataplane for the RT-BE88U (aarch64 musl) and
# pack it with the addon scripts. The archive is gitignored under merlin/dist.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
rustup target add aarch64-unknown-linux-musl
if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    echo "merlin/build.sh: install gcc-aarch64-linux-gnu so rustc can pass --fix-cortex-a53-843419" >&2
    exit 1
fi
# The host bfd linker rejects rustc's Cortex-A53 errata flag. The aarch64
# cross gcc accepts it and still links the musl CRT rustc passes in.
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-linux-gnu-gcc \
    cargo build -p honk-dataplane --release --target aarch64-unknown-linux-musl
bin=$root/target/aarch64-unknown-linux-musl/release/honk-dataplane
stage=$(mktemp -d)
mkdir -p "$stage/honk/scripts" "$stage/honk/www"
cp "$bin" "$stage/honk/honk-dataplane"
cp -R "$root/merlin/scripts/." "$stage/honk/scripts/"
cp -R "$root/merlin/www/." "$stage/honk/www/"
cp "$root/merlin/README_merlin.md" "$stage/honk/README_merlin.md"
chmod 755 "$stage/honk/honk-dataplane" "$stage/honk/scripts/"*.sh
mkdir -p "$root/merlin/dist"
tar -C "$stage" -czf "$root/merlin/dist/honk-be88u.tar.gz" honk
rm -rf "$stage"
file "$bin"
echo "wrote $root/merlin/dist/honk-be88u.tar.gz"
