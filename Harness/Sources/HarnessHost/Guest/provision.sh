#!/bin/bash
# Installs the patched Valgrind and the counter shim under a prefix: /opt in the guest, a cache
# directory on a Linux host.
#
# The first run builds Valgrind from the verified source tarball, with the local patch (NOTES.md), and
# caches the installation as an archive; later runs only unpack it, once per prefix. Building needs
# make, gcc, the C library's headers, bzip2 and patch; as root with apt-get they are installed when
# missing. Concurrent runs may share a prefix: each step lands by an atomic rename.
#
# Usage: provision.sh <valgrind source tarball> <cached installation archive> <guest files directory>
#        <prefix>
set -euo pipefail
tarball=$1
archive=$2
files=$3
prefix=$4
export DEBIAN_FRONTEND=noninteractive
mkdir -p "$prefix"

if [ ! -f "$archive" ]; then
    echo "Building Valgrind (once; cached in $archive)" >&2
    missing=no
    for tool in make gcc bzip2 patch; do command -v "$tool" >/dev/null || missing=yes; done
    [ -f /usr/include/stdio.h ] || missing=yes
    if [ "$missing" = yes ]; then
        if [ "$(id -u)" = 0 ] && command -v apt-get >/dev/null; then
            sed -i 's|http://ports.ubuntu.com|https://ports.ubuntu.com|g' /etc/apt/sources.list.d/*.sources
            apt-get update -qq >/dev/null
            apt-get install -y -qq --no-install-recommends make gcc libc6-dev bzip2 patch >/dev/null
        else
            echo "Building Valgrind needs make, gcc, the C library headers, bzip2 and patch" >&2
            exit 1
        fi
    fi
    build=$(mktemp -d)
    tar -xjf "$tarball" -C "$build"
    cd "$build"/valgrind-*
    patch -p1 --quiet < "$files/valgrind.patch"
    log=$(mktemp)
    # Installed into a staging root, so a failed build leaves nothing under the prefix.
    if ! { ./configure --prefix="$prefix/valgrind" && make -j"$(nproc)" && make install DESTDIR="$build/root"; } >"$log" 2>&1; then
        tail -40 "$log" >&2
        exit 1
    fi
    tar -C "$build/root$prefix" -cf "$archive.partial.$$" valgrind
    mv "$archive.partial.$$" "$archive"
    cd /
    rm -rf "$build"
fi

if [ ! -x "$prefix/valgrind/bin/valgrind" ]; then
    staging=$(mktemp -d "$prefix/.valgrind.XXXXXX")
    tar -C "$staging" -xf "$archive"
    mv -T "$staging/valgrind" "$prefix/valgrind" 2>/dev/null || true
    rm -rf "$staging"
fi
clang -O2 -shared -fPIC -I"$prefix/valgrind/include" -o "$prefix/perfshim.so.$$" "$files/perfshim.c" -ldl
mv -f "$prefix/perfshim.so.$$" "$prefix/perfshim.so"
