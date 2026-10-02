#!/bin/bash
# Build a local Crystal compiler WITH interpreter support (interpreter=1).
#
# Official Linux builds ship WITHOUT the interpreter, so `crystal i`
# (instant, stateful eval) is unavailable there. This script builds one
# from source into ~/.local/share/icr/ — icr picks it up automatically
# (see Icr.interpreter_bin). Nothing is installed system-wide.
#
# Requirements: build essentials, LLVM dev (llvm-config in PATH),
# libgc/libevent/libffi/openssl/zlib dev packages; libyaml is built
# here if the system doesn't have it.
set -e

ICR_HOME="$HOME/.local/share/icr"
ROOT="$ICR_HOME/root"
VERSION="1.21.0"
mkdir -p "$ROOT" "$ICR_HOME"

# --- libyaml (often missing) --------------------------------------------------
if [ ! -f "$ROOT/lib/libyaml.a" ]; then
  echo "=== building libyaml ==="
  curl -sL -o "$ICR_HOME/yaml-0.2.5.tar.gz" \
    https://github.com/yaml/libyaml/releases/download/0.2.5/yaml-0.2.5.tar.gz
  tar -C "$ICR_HOME" -xzf "$ICR_HOME/yaml-0.2.5.tar.gz"
  ( cd "$ICR_HOME/yaml-0.2.5" \
    && ./configure --prefix="$ROOT" --disable-shared --enable-static \
    && make -j"$(nproc)" && make install )
fi
echo "=== libyaml OK ==="

# --- crystal with interpreter -------------------------------------------------
echo "=== building crystal $VERSION (interpreter=1) ==="
curl -sL -o "$ICR_HOME/crystal-$VERSION.tar.gz" \
  "https://github.com/crystal-lang/crystal/archive/refs/tags/$VERSION.tar.gz"
rm -rf "$ICR_HOME/crystal-$VERSION-src"
tar -C "$ICR_HOME" -xzf "$ICR_HOME/crystal-$VERSION.tar.gz"
mv "$ICR_HOME/crystal-$VERSION" "$ICR_HOME/crystal-$VERSION-src"
cd "$ICR_HOME/crystal-$VERSION-src"

export PKG_CONFIG_PATH="$ROOT/lib/pkgconfig"
export CRYSTAL_LIBRARY_PATH="$ROOT/lib"
make interpreter=1 -j"$(nproc)"

# expose as the icr-local compiler (version-stable symlink)
rm -rf "$ICR_HOME/crystal"
ln -s "$ICR_HOME/crystal-$VERSION-src" "$ICR_HOME/crystal"

echo "=== BUILD DONE ==="
echo "=== interpreter installed at $ICR_HOME/crystal/bin/crystal ==="
