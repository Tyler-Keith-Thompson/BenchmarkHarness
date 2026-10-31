#!/bin/bash
# Installs the patched Valgrind and the counter shim in the guest.
#
# The first run builds Valgrind from the verified source tarball, with the rt_sigsuspend patch, and
# caches the installation as an archive on the shared volume; later runs only unpack it.
#
# Usage: provision.sh <valgrind source tarball> <cached installation archive> <guest files directory>
set -euo pipefail
tarball=$1
archive=$2
files=$3
export DEBIAN_FRONTEND=noninteractive

if [ ! -f "$archive" ]; then
    echo "Building Valgrind (once; cached in $archive)" >&2
    sed -i 's|http://ports.ubuntu.com|https://ports.ubuntu.com|g' /etc/apt/sources.list.d/*.sources
    apt-get update -qq >/dev/null
    apt-get install -y -qq --no-install-recommends make gcc libc6-dev bzip2 >/dev/null
    build=$(mktemp -d)
    tar -xjf "$tarball" -C "$build"
    cd "$build"/valgrind-*
    patch -p1 --quiet < "$files/valgrind-rt_sigsuspend.patch"
    log=$(mktemp)
    if ! { ./configure --prefix=/opt/valgrind && make -j"$(nproc)" && make install; } >"$log" 2>&1; then
        tail -40 "$log" >&2
        exit 1
    fi
    tar -C /opt -cf "$archive.partial" valgrind
    mv "$archive.partial" "$archive"
fi

rm -rf /opt/valgrind
tar -C /opt -xf "$archive"
clang -O2 -shared -fPIC -I/opt/valgrind/include -o /opt/perfshim.so "$files/perfshim.c" -ldl
