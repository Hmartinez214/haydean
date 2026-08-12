#!/bin/bash
# Smoke-test MPI on a single node, run from the shared benchmark dir.
cd /home/hpcadmin/storagebenchmarks || exit 1
mpicc -o hello_bin hello.c || exit 1
echo "--- compiled, launching ---"
mpirun -n 4 ./hello_bin
echo "--- exit=$? ---"
