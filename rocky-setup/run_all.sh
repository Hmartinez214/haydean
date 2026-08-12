#!/bin/bash
# Rocky port of run_all.sh
#
# Changes from the Ubuntu original: only the usage examples (apt → dnf).
# The script itself is OS-independent.

HOSTS=("haydean1" "haydean2" "haydean3" "haydean4")

if [ $# -eq 0 ]; then
    echo "Usage: $0 '<command to run>'"
    echo "Example: $0 'sudo dnf install -y btop'"
    echo "Example: $0 'hostname && uptime'"
    exit 1
fi

CMD="$*"

for host in "${HOSTS[@]}"; do
    echo "======================================"
    echo "Running on $host:"
    echo "$CMD"
    echo "======================================"

    ssh "$host" "$CMD"

    if [ $? -eq 0 ]; then
        echo "✅ Success on $host"
    else
        echo "❌ Failed on $host"
    fi

    echo
done
