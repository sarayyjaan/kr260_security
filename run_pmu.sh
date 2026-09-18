#!/bin/sh

# Usage:
#   ./run_pmu.sh native
#   ./run_pmu.sh bao
#   ./run_pmu.sh native 20
#
# Default repetitions = 20

MODE="${1:-native}"
REPEATS="${2:-20}"

BASE="/mnt/sd/bench"
QSORT="$BASE/mibench/qsort"
BITCOUNT="$BASE/mibench/bitcount"

# --------------------------------------------------
# Verify persistent SD storage
# --------------------------------------------------

if ! grep -q " /mnt/sd " /proc/mounts; then
    echo "ERROR: /mnt/sd is not mounted."
    echo "Run:"
    echo "  mkdir -p /mnt/sd"
    echo "  mount /dev/sda2 /mnt/sd"
    exit 1
fi

# --------------------------------------------------
# Verify workloads
# --------------------------------------------------

if [ ! -x "$QSORT/qsort_large" ]; then
    echo "ERROR: qsort_large not found."
    exit 1
fi

if [ ! -x "$BITCOUNT/bitcnts" ]; then
    echo "ERROR: bitcnts not found."
    exit 1
fi

# --------------------------------------------------
# Results directory
# --------------------------------------------------

STAMP=$(date +%Y%m%d_%H%M%S)

OUT="$BASE/results/$MODE/$STAMP"

mkdir -p "$OUT/qsort"
mkdir -p "$OUT/bitcount"

echo "Results directory:"
echo "$OUT"

# --------------------------------------------------
# Metadata
# --------------------------------------------------

{
    echo "MODE=$MODE"
    echo "REPEATS=$REPEATS"
    echo "DATE=$(date)"
    echo

    echo "===== uname ====="
    uname -a

    echo
    echo "===== command line ====="
    cat /proc/cmdline

    echo
    echo "===== CPU info ====="
    cat /proc/cpuinfo

    echo
    echo "===== perf version ====="
    perf --version

    echo
    echo "===== Available PMU events ====="

    for d in /sys/bus/event_source/devices/*/events; do
        if [ -e "$d/inst_retired" ]; then
            echo "PMU=$d"
            ls -1 "$d" | sort
            break
        fi
    done

} > "$OUT/metadata.txt"

# --------------------------------------------------
# Actual Cortex-A53 events exposed by THIS kernel
#
# cpu_cycles is repeated because it can use the
# dedicated cycle counter.
# --------------------------------------------------

EXEC_EVENTS="
cpu_cycles
inst_retired
ld_retired
st_retired
br_pred
br_mis_pred
br_immed_retired
"

DATA_EVENTS="
cpu_cycles
l1d_cache
l1d_cache_refill
l1d_cache_wb
l1d_tlb_refill
mem_access
bus_access
"

CACHE_EVENTS="
cpu_cycles
l2d_cache
l2d_cache_refill
l2d_cache_wb
l1i_cache
l1i_cache_refill
l1i_tlb_refill
"

SYSTEM_EVENTS="
cpu_cycles
bus_cycles
exc_taken
exc_return
unaligned_ldst_retired
cid_write_retired
pc_write_retired
"

ERROR_EVENTS="
cpu_cycles
memory_error
"

# --------------------------------------------------
# Privilege levels
# --------------------------------------------------

PRIVS="default u k uk h"

# --------------------------------------------------
# Convert:
#
#   cpu_cycles inst_retired
#
# into:
#
#   cpu_cycles:u,inst_retired:u
# --------------------------------------------------

make_events()
{
    EVENTS="$1"
    PRIV="$2"

    RESULT=""

    for EVENT in $EVENTS; do

        if [ "$PRIV" = "default" ]; then
            SPEC="$EVENT"
        else
            SPEC="$EVENT:$PRIV"
        fi

        if [ -z "$RESULT" ]; then
            RESULT="$SPEC"
        else
            RESULT="$RESULT,$SPEC"
        fi

    done

    echo "$RESULT"
}

# --------------------------------------------------
# Run one measurement set
# --------------------------------------------------

measure()
{
    WORKLOAD="$1"
    GROUP="$2"
    EVENTS="$3"
    PRIV="$4"

    EVENT_STRING=$(make_events "$EVENTS" "$PRIV")

    FILE="$OUT/$WORKLOAD/${GROUP}_${PRIV}.csv"

    echo "Running:"
    echo "  $WORKLOAD / $GROUP / $PRIV"

    {
        echo "# workload=$WORKLOAD"
        echo "# group=$GROUP"
        echo "# privilege=$PRIV"
        echo "# repetitions=$REPEATS"
        echo "# events=$EVENT_STRING"
    } > "$FILE"

    RUN=1

    while [ "$RUN" -le "$REPEATS" ]; do

        echo "# RUN=$RUN" >> "$FILE"

        if [ "$WORKLOAD" = "qsort" ]; then

            (
                cd "$QSORT" || exit 1

                taskset -c 0 perf stat \
                    -x ';' \
                    -e "$EVENT_STRING" \
                    -- ./qsort_large input_large.dat \
                    >/dev/null

            ) 2>> "$FILE"

        elif [ "$WORKLOAD" = "bitcount" ]; then

            (
                cd "$BITCOUNT" || exit 1

                taskset -c 0 perf stat \
                    -x ';' \
                    -e "$EVENT_STRING" \
                    -- ./bitcnts 11250000 \
                    >/dev/null

            ) 2>> "$FILE"

        fi

        RUN=$((RUN + 1))

    done
}

# --------------------------------------------------
# Warm-up
# --------------------------------------------------

echo "Warming up qsort..."

(
    cd "$QSORT" || exit 1
    taskset -c 0 ./qsort_large input_large.dat >/dev/null
)

echo "Warming up bitcount..."

(
    cd "$BITCOUNT" || exit 1
    taskset -c 0 ./bitcnts 11250000 >/dev/null
)

# --------------------------------------------------
# Collect everything
# --------------------------------------------------

for PRIV in $PRIVS; do

    # Qsort
    measure qsort execution "$EXEC_EVENTS" "$PRIV"
    measure qsort data      "$DATA_EVENTS" "$PRIV"
    measure qsort cache     "$CACHE_EVENTS" "$PRIV"
    measure qsort system    "$SYSTEM_EVENTS" "$PRIV"
    measure qsort error     "$ERROR_EVENTS" "$PRIV"

    # Bitcount
    measure bitcount execution "$EXEC_EVENTS" "$PRIV"
    measure bitcount data      "$DATA_EVENTS" "$PRIV"
    measure bitcount cache     "$CACHE_EVENTS" "$PRIV"
    measure bitcount system    "$SYSTEM_EVENTS" "$PRIV"
    measure bitcount error     "$ERROR_EVENTS" "$PRIV"

done

sync

echo
echo "=========================================="
echo "Finished"
echo "=========================================="
echo
echo "Results:"
echo "$OUT"
echo

find "$OUT" -type f -print
