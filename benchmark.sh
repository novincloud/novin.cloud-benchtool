#!/usr/bin/env bash
# Robust Ubuntu 24.x minimal benchmark script
# - CPU single-core score (sysbench events/sec)
# - Memory throughput (MiB/s)
# - Disk: seq write/read, rand write/read (MiB/s)
# - Network speed test (Mb/s + ping)
# Safe: engine detection, timeouts, JSON parsing; prints summary even on partial failures.

set -u  # keep -u only; we'll handle errors manually

# -------- Config (overridable via env) --------
: "${TESTDIR:=/tmp/bench}"
: "${FILESIZE:=2G}"        # disk test file size
: "${DURATION:=30}"        # seconds for random fio tests
: "${CPU_PRIME:=20000}"    # sysbench prime limit (single-core)
: "${MEM_TOTAL:=1G}"       # total transfer for memory test (kept modest for speed)
: "${FIO_TIMEOUT:=900}"    # max seconds for any single fio job
: "${NET_TIMEOUT:=120}"    # seconds for network test

# -------- State / Results --------
CPU_SINGLE="N/A"
MEM_MIBS="N/A"
SEQ_WRITE_MIBS="N/A"
SEQ_READ_MIBS="N/A"
RAND_WRITE_MIBS="N/A"
RAND_READ_MIBS="N/A"
NET_DL="N/A"
NET_UL="N/A"
NET_PING="N/A"
TESTFILE=""
FIO_ENGINE=""

b() { printf "\e[1;34m[bench]\e[0m %s\n" "$*"; }
w() { printf "\e[1;33m[warn]\e[0m %s\n" "$*"; }
e() { printf "\e[1;31m[err]\e[0m %s\n" "$*"; }

cleanup() {
  [[ -n "$TESTFILE" && -f "$TESTFILE" ]] && rm -f "$TESTFILE" || true
}
trap cleanup EXIT INT TERM

require_root() {
  if [ "$(id -u)" -ne 0 ]; then e "Please run as root (sudo)."; exit 1; fi
}

install_tools() {
  b "Updating apt and installing tools (sysbench, fio, jq, bc, speedtest-cli, core utils)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || apt-get update -y
  apt-get install -y --no-install-recommends sysbench fio jq bc ca-certificates speedtest-cli coreutils >/dev/null 2>&1 || \
  apt-get install -y --no-install-recommends sysbench fio jq bc ca-certificates speedtest-cli coreutils
}

prepare_dirs() {
  mkdir -p "$TESTDIR"
  TESTFILE="${TESTDIR%/}/fio_testfile.dat"
  b "Test directory: $TESTDIR"
}

detect_fio_engine() {
  # Pick first available/working engine among io_uring, libaio, psync
  local eng
  for eng in io_uring libaio psync; do
    if fio --enghelp 2>/dev/null | grep -q "^$eng$"; then
      FIO_ENGINE="$eng"
      break
    fi
  done
  if [ -z "$FIO_ENGINE" ]; then
    # Fallback: try running psync anyway
    FIO_ENGINE="psync"
  fi
  b "Using fio engine: $FIO_ENGINE"
}

# -------- CPU --------
cpu_bench() {
  b "CPU single-core (sysbench primes=$CPU_PRIME, threads=1)..."
  local out
  if out="$(sysbench cpu --cpu-max-prime="$CPU_PRIME" --threads=1 run 2>/dev/null)"; then
    CPU_SINGLE="$(printf "%s\n" "$out" | awk -F': *' '/events per second/ {print $2; exit}' | tr -d ' ')"
    [ -z "$CPU_SINGLE" ] && CPU_SINGLE="N/A"
  else
    w "sysbench CPU test failed."
  fi
}

# -------- Memory --------
mem_bench() {
  b "Memory throughput (sysbench total=$MEM_TOTAL, 1M blocks, 1 thread)..."
  local out
  if out="$(sysbench memory --memory-block-size=1M --memory-total-size="$MEM_TOTAL" --threads=1 run 2>/dev/null)"; then
    MEM_MIBS="$(printf "%s\n" "$out" | awk -F'[()]' '/MiB transferred/ {gsub(/ MiB\/sec/,"",$2); print $2; exit}' | tr -d ' ')"
    [ -z "$MEM_MIBS" ] && MEM_MIBS="N/A"
  else
    w "sysbench memory test failed."
  fi
}

# -------- Disk (fio JSON + jq) --------
check_space() {
  # Reduce FILESIZE if not enough space
  local need have
  need="$(numfmt --from=iec "$FILESIZE" 2>/dev/null || echo 0)"
  have="$(df -PB1 "$TESTDIR" | awk 'NR==2 {print $4}')"
  if [ "$need" -gt 0 ] && [ "$have" -lt "$need" ]; then
    w "Not enough free space for $FILESIZE in $TESTDIR (have $(numfmt --to=iec "$have")). Using 1G."
    FILESIZE="1G"
  fi
}

run_fio_json() {
  # $1: name, $2: fio args (rw, bs, size/time flags)
  local name="$1"; shift
  local outjson="$TESTDIR/${name}.json"
  timeout "$FIO_TIMEOUT" fio --name="$name" --filename="$TESTFILE" --ioengine="$FIO_ENGINE" --direct=1 \
    --group_reporting=1 --output-format=json --output="$outjson" "$@" >/dev/null 2>&1
  echo "$outjson"
}

parse_bw_mibs() {
  # $1 json path, $2 read|write
  local json="$1" mode="$2"
  if [ -s "$json" ]; then
    # fio reports bw_bytes per second; convert to MiB/s
    jq -r --arg mode "$mode" '.jobs[0][$mode].bw_bytes' "$json" 2>/dev/null | \
      awk '{if($1 ~ /^[0-9]+$/){printf "%.2f", ($1/1048576)} else {print "N/A"}}'
  else
    echo "N/A"
  fi
}

disk_bench() {
  check_space
  b "Sequential write $FILESIZE (1M blocks)..."
  local j
  j="$(run_fio_json seqwrite --size="$FILESIZE" --bs=1M --rw=write --iodepth=64 --numjobs=1)"
  SEQ_WRITE_MIBS="$(parse_bw_mibs "$j" write)"

  b "Sequential read $FILESIZE (1M blocks)..."
  j="$(run_fio_json seqread --size="$FILESIZE" --bs=1M --rw=read --iodepth=64 --numjobs=1)"
  SEQ_READ_MIBS="$(parse_bw_mibs "$j" read)"

  b "Random read (4k, ${DURATION}s)..."
  j="$(run_fio_json randread --size="$FILESIZE" --bs=4k --rw=randread --iodepth=64 --numjobs=1 --time_based=1 --runtime="$DURATION")"
  RAND_READ_MIBS="$(parse_bw_mibs "$j" read)"

  b "Random write (4k, ${DURATION}s)..."
  j="$(run_fio_json randwrite --size="$FILESIZE" --bs=4k --rw=randwrite --iodepth=64 --numjobs=1 --time_based=1 --runtime="$DURATION")"
  RAND_WRITE_MIBS="$(parse_bw_mibs "$j" write)"
}

# -------- Network --------
net_bench() {
  b "Network speed test (speedtest-cli)..."
  # Prefer JSON; guard with timeout
  local json=""
  if json="$(timeout "$NET_TIMEOUT" speedtest-cli --json 2>/dev/null)"; then
    # speedtest-cli reports bits/s
    NET_DL="$(printf "%s" "$json" | jq -r '.download // empty' | awk '{if($1=="")print "N/A"; else printf "%.2f", $1/1000000}')"
    NET_UL="$(printf "%s" "$json" | jq -r '.upload // empty'   | awk '{if($1=="")print "N/A"; else printf "%.2f", $1/1000000}')"
    NET_PING="$(printf "%s" "$json" | jq -r '.ping // empty'   | awk '{if($1=="")print "N/A"; else printf "%.2f", $1}')"
  else
    w "speedtest-cli JSON failed or timed out; trying text mode."
    local out=""
    out="$(timeout "$NET_TIMEOUT" speedtest-cli 2>/dev/null || true)"
    NET_DL="$(printf "%s\n" "$out" | awk -F': *' '/Download:/ {gsub(/ Mbit\/s/,"",$2); gsub(/ /,"",$2); print $2; exit}')"
    NET_UL="$(printf "%s\n" "$out" | awk -F': *' '/Upload:/   {gsub(/ Mbit\/s/,"",$2); gsub(/ /,"",$2); print $2; exit}')"
    NET_PING="$(printf "%s\n" "$out" | awk -F': *' '/Ping:/     {gsub(/ ms/,"",$2); gsub(/ /,"",$2); print $2; exit}')"
    [ -z "$NET_DL" ] && NET_DL="N/A"
    [ -z "$NET_UL" ] && NET_UL="N/A"
    [ -z "$NET_PING" ] && NET_PING="N/A"
  fi
}

# -------- Summary --------
print_summary() {
  echo
  echo "=================== Benchmark Summary ==================="
  printf "CPU (single-core 'CPUMark', sysbench events/sec):  %s\n" "$CPU_SINGLE"
  printf "Memory throughput (MiB/s):                         %s\n" "$MEM_MIBS"
  echo "Disk throughput (MiB/s):"
  printf "  - Sequential Write:                              %s\n" "$SEQ_WRITE_MIBS"
  printf "  - Sequential Read:                               %s\n" "$SEQ_READ_MIBS"
  printf "  - Random Write (4k):                             %s\n" "$RAND_WRITE_MIBS"
  printf "  - Random Read  (4k):                             %s\n" "$RAND_READ_MIBS"
  echo "Network:"
  printf "  - Download (Mb/s):                               %s\n" "$NET_DL"
  printf "  - Upload   (Mb/s):                               %s\n" "$NET_UL"
  printf "  - Ping (ms):                                     %s\n" "$NET_PING"
  echo "========================================================="
  echo
  jq -n \
    --arg cpu_single "$CPU_SINGLE" \
    --arg mem_mibs "$MEM_MIBS" \
    --arg seq_w "$SEQ_WRITE_MIBS" \
    --arg seq_r "$SEQ_READ_MIBS" \
    --arg rnd_w "$RAND_WRITE_MIBS" \
    --arg rnd_r "$RAND_READ_MIBS" \
    --arg dl "$NET_DL" \
    --arg ul "$NET_UL" \
    --arg ping "$NET_PING" \
    '{
      cpu_single_events_per_sec: $cpu_single,
      memory_mib_per_sec: $mem_mibs,
      disk: {
        sequential_write_mib_per_sec: $seq_w,
        sequential_read_mib_per_sec:  $seq_r,
        random_write_4k_mib_per_sec:  $rnd_w,
        random_read_4k_mib_per_sec:   $rnd_r
      },
      network: {
        download_Mbps: $dl,
        upload_Mbps:   $ul,
        ping_ms:       $ping
      }
    }'
}

main() {
  require_root
  install_tools
  prepare_dirs
  detect_fio_engine
  cpu_bench
  mem_bench
  disk_bench
  net_bench
  print_summary
}

main "$@"
