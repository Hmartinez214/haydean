#!/bin/bash
# Build IOR (which provides ior + mdtest) into the shared NFS path so every
# compute node sees the same binaries.
set -e

SRC=/home/hpcadmin/storagebenchmarks/src/ior
PREFIX=/home/hpcadmin/storagebenchmarks/opt

cd "$SRC"
./bootstrap
./configure --prefix="$PREFIX" CC=mpicc MPICC=mpicc
make -j"$(nproc)"
make install

echo "=== installed ==="
ls -la "$PREFIX/bin"
