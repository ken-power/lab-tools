#!/usr/bin/env bash
#
# labcheck.sh — report which lab nodes listed in /etc/hosts are up and reachable.
#
# Check levels (cumulative):
#   2  ping + TCP connect to the SSH port      (OS booted, sshd listening)
#   3  + non-interactive SSH login             (node is actually usable)
#   4  + health summary over SSH (default)     (OS, uptime, load, mem, disk, GPU)
#
# Works on macOS (stock bash 3.2) and Linux. Remote nodes may be macOS or Linux.
# Levels 3/4 need key-based SSH (ssh-agent or unencrypted key); password auth
# is never attempted (BatchMode=yes), so the script never hangs on a prompt.

set -u

LEVEL=4
PORT=22
PORT_SET=0
TIMEOUT=3
HOSTS_FILE=/etc/hosts
TAG=""
SUBNET=""
SSH_USER=""

usage() {
  cat <<'EOF'
Usage: labcheck.sh [options] [node ...]

Checks every lab node found in /etc/hosts (loopback, broadcast, IPv6 and
Docker entries are skipped). Name specific nodes to check only those.

Options:
  -l LEVEL     check depth: 2 = ping + port, 3 = + SSH login,
               4 = + health summary (default: 4)
  -t SECS      per-check timeout in seconds (default: 3)
  -p PORT      SSH/TCP port (default: 22, or whatever ~/.ssh/config says
               for the SSH login itself)
  -u USER      SSH user (default: from ~/.ssh/config or current user)
  -g TAG       only nodes whose /etc/hosts line has a "# TAG" comment
  -s PREFIX    only nodes whose IP starts with PREFIX (e.g. 192.168.1.)
  -f FILE      hosts file to read (default: /etc/hosts)
  -h           show this help

Exit status: 0 if every node passes at the chosen level, 1 otherwise.
Set NO_COLOR=1 to disable colors.
EOF
}

while getopts ":l:t:p:u:g:s:f:h" opt; do
  case $opt in
    l) LEVEL=$OPTARG ;;
    t) TIMEOUT=$OPTARG ;;
    p) PORT=$OPTARG; PORT_SET=1 ;;
    u) SSH_USER=$OPTARG ;;
    g) TAG=$OPTARG ;;
    s) SUBNET=$OPTARG ;;
    f) HOSTS_FILE=$OPTARG ;;
    h) usage; exit 0 ;;
    :) echo "labcheck: -$OPTARG needs a value" >&2; exit 2 ;;
    *) echo "labcheck: unknown option -$OPTARG" >&2; usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

case $LEVEL in 2|3|4) ;; *) echo "labcheck: -l must be 2, 3 or 4" >&2; exit 2 ;; esac
case $TIMEOUT in ''|*[!0-9]*) echo "labcheck: -t must be whole seconds" >&2; exit 2 ;; esac
case $PORT in ''|*[!0-9]*) echo "labcheck: -p must be a port number" >&2; exit 2 ;; esac
[ "$TIMEOUT" -ge 1 ] || TIMEOUT=1

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_OK=""; C_BAD=""; C_WARN=""; C_DIM=""; C_BOLD=""; C_RST=""
fi

LOCAL_OS=$(uname -s)
TMPDIR_LC=$(mktemp -d "${TMPDIR:-/tmp}/labcheck.XXXXXX") || exit 2
trap 'rm -rf "$TMPDIR_LC"' EXIT INT TERM

# ---------------------------------------------------------------------------
# Node list from /etc/hosts. Output: "name ip" per line, deduplicated.
# ---------------------------------------------------------------------------
parse_hosts() {
  awk -v tag="$TAG" -v subnet="$SUBNET" '
  {
    comment = ""
    i = index($0, "#")
    if (i > 0) { comment = substr($0, i + 1); $0 = substr($0, 1, i - 1) }
    if (NF < 2) next
    ip = $1; name = $2

    if (ip ~ /:/) next                                   # IPv6 (incl. ::1, fe80, ff0x)
    if (ip ~ /^127\./ || ip == "0.0.0.0" || ip == "255.255.255.255") next
    if (name ~ /^localhost(\.|$)/ || name == "broadcasthost") next
    if (name ~ /^ip6-/ || name ~ /docker\.internal$/) next
    if (subnet != "" && index(ip, subnet) != 1) next
    if (tag != "" && comment !~ ("(^|[ \t,])" tag "([ \t,]|$)")) next

    if (seen_ip[ip]++ || seen_name[name]++) next
    print name, ip
  }' "$HOSTS_FILE"
}

# ---------------------------------------------------------------------------
# Run a command with a hard timeout (no `timeout` on stock macOS).
# Usage: with_timeout SECS STDIN_FILE cmd [args...]
# Returns the command's status, or 143 if it was killed.
# ---------------------------------------------------------------------------
with_timeout() {
  local secs=$1 input=$2; shift 2
  "$@" <"$input" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) \
    >/dev/null 2>&1 &
  local watcher=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return $rc
}

do_ping() {
  case $LOCAL_OS in
    Darwin) ping -c 1 -t "$TIMEOUT" "$1" ;;   # -t = total timeout (s) on macOS
    *)      ping -c 1 -W "$TIMEOUT" "$1" ;;   # -W = reply timeout (s) on Linux
  esac >/dev/null 2>&1
}

# Prints open | closed | timeout
do_tcp() {
  with_timeout "$TIMEOUT" /dev/null bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$PORT" \
    >/dev/null 2>&1
  case $? in
    0)   echo open ;;
    143|137) echo timeout ;;
    *)   echo closed ;;
  esac
}

# ---------------------------------------------------------------------------
# Health probe, run on the remote node via `sh -s`. POSIX sh; macOS or Linux.
# ---------------------------------------------------------------------------
cat >"$TMPDIR_LC/health.sh" <<'REMOTE'
os=$(uname -s); arch=$(uname -m)
up=; load=; ncpu=; mem=; disk=; gpu=-
if [ "$os" = Darwin ]; then
  osname="macOS $(sw_vers -productVersion 2>/dev/null)"
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed 's/^{ sec = \([0-9]*\).*/\1/')
  [ -n "$boot" ] && up=$(( $(date +%s) - boot ))
  load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
  ncpu=$(sysctl -n hw.ncpu 2>/dev/null)
  free=$(memory_pressure -Q 2>/dev/null | awk -F': *' '/free percentage/ {sub(/%/, "", $2); print $2}')
  [ -n "$free" ] && mem=$((100 - free))
  dpath=/System/Volumes/Data; [ -d "$dpath" ] || dpath=/
  disk=$(df -P "$dpath" 2>/dev/null | awk 'NR == 2 {sub(/%/, "", $5); print $5}')
else
  if [ -r /etc/os-release ]; then
    osname=$(. /etc/os-release; echo "${NAME:-Linux} ${VERSION_ID:-}")
  else
    osname=Linux
  fi
  up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
  load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
  ncpu=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)
  mem=$(awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2}
             END {if (t > 0) printf "%d", (t - a) * 100 / t}' /proc/meminfo 2>/dev/null)
  disk=$(df -P / 2>/dev/null | awk 'NR == 2 {sub(/%/, "", $5); print $5}')
  if command -v nvidia-smi >/dev/null 2>&1; then
    g=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null \
        | head -n 1 | tr -d ' ')
    case $g in ''|*[!0-9]*) gpu=yes ;; *) gpu="$g%" ;; esac
  fi
fi
printf 'os=%s\narch=%s\nup=%s\nload=%s\nncpu=%s\nmem=%s\ndisk=%s\ngpu=%s\n' \
  "$osname" "$arch" "$up" "$load" "$ncpu" "$mem" "$disk" "$gpu"
REMOTE

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout="$TIMEOUT" -o LogLevel=ERROR)
[ "$PORT_SET" = 1 ] && SSH_OPTS+=(-p "$PORT")
SSH_CMD_TIMEOUT=$((TIMEOUT + 10))   # login + nvidia-smi can be slow on Tegra/Thor

# Classify an SSH failure from its stderr and exit status.
ssh_reason() {
  local err=$1 rc=$2
  if [ "$rc" = 143 ] || [ "$rc" = 137 ]; then echo timeout
  elif grep -q 'Permission denied' "$err"; then echo auth
  elif grep -qi 'host key\|IDENTIFICATION HAS CHANGED' "$err"; then echo hostkey
  elif grep -q 'Connection refused' "$err"; then echo refused
  elif grep -qi 'timed out' "$err"; then echo timeout
  else echo fail
  fi
}

fmt_uptime() {
  case ${1:-} in ''|*[!0-9]*) echo -; return ;; esac
  local s=$1 d h m
  d=$((s / 86400)); h=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
  if [ $d -gt 0 ]; then echo "${d}d${h}h"
  elif [ $h -gt 0 ]; then echo "${h}h${m}m"
  else echo "${m}m"
  fi
}

# ---------------------------------------------------------------------------
# Check one node; writes a single '|'-separated record to $3.
# Fields: name|ip|ping|tcp|login|os|arch|uptime|load|ncpu|mem|disk|gpu|ok
# ---------------------------------------------------------------------------
check_node() {
  local name=$1 ip=$2 out=$3
  local ping=no tcp login=- ok=0
  local r_os=- r_arch=- r_up=- r_load=- r_ncpu=- r_mem=- r_disk=- r_gpu=-

  do_ping "$ip" && ping=yes
  tcp=$(do_tcp "$ip")

  if [ "$LEVEL" -ge 3 ]; then
    if [ "$tcp" = open ]; then
      local target=$name rc
      [ -n "$SSH_USER" ] && target="$SSH_USER@$name"
      if [ "$LEVEL" -ge 4 ]; then
        with_timeout "$SSH_CMD_TIMEOUT" "$TMPDIR_LC/health.sh" \
          ssh "${SSH_OPTS[@]}" "$target" 'sh -s' >"$out.stdout" 2>"$out.stderr"
      else
        with_timeout "$SSH_CMD_TIMEOUT" /dev/null \
          ssh "${SSH_OPTS[@]}" "$target" true >"$out.stdout" 2>"$out.stderr"
      fi
      rc=$?
      if [ $rc = 0 ]; then
        login=ok
      else
        login=$(ssh_reason "$out.stderr" "$rc")
      fi
      if [ "$login" = ok ] && [ "$LEVEL" -ge 4 ]; then
        local k v
        while IFS='=' read -r k v; do
          [ -n "$v" ] || continue
          case $k in
            os) r_os=$v ;; arch) r_arch=$v ;; up) r_up=$v ;; load) r_load=$v ;;
            ncpu) r_ncpu=$v ;; mem) r_mem=$v ;; disk) r_disk=$v ;; gpu) r_gpu=$v ;;
          esac
        done <"$out.stdout"
      fi
    else
      login=skip
    fi
    [ "$login" = ok ] && ok=1
  else
    [ "$tcp" = open ] && ok=1
  fi

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$name" "$ip" "$ping" "$tcp" "$login" "$r_os" "$r_arch" "$r_up" \
    "$r_load" "$r_ncpu" "$r_mem" "$r_disk" "$r_gpu" "$ok" >"$out"
}

# ---------------------------------------------------------------------------
# Build the node list
# ---------------------------------------------------------------------------
if [ ! -r "$HOSTS_FILE" ]; then
  echo "labcheck: cannot read $HOSTS_FILE" >&2; exit 2
fi

ALL=$(parse_hosts)
NAMES=(); IPS=()
if [ $# -gt 0 ]; then
  for want in "$@"; do
    ip=$(printf '%s\n' "$ALL" | awk -v n="$want" '$1 == n {print $2; exit}')
    NAMES+=("$want"); IPS+=("${ip:-$want}")
  done
else
  while read -r n i; do
    [ -n "$n" ] && { NAMES+=("$n"); IPS+=("$i"); }
  done <<EOF
$ALL
EOF
fi

if [ ${#NAMES[@]} -eq 0 ]; then
  echo "labcheck: no nodes found in $HOSTS_FILE (check -g / -s filters)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Run all checks in parallel, then print in /etc/hosts order
# ---------------------------------------------------------------------------
for idx in "${!NAMES[@]}"; do
  check_node "${NAMES[$idx]}" "${IPS[$idx]}" "$TMPDIR_LC/node.$idx" &
done
wait

w_name=4
for n in "${NAMES[@]}"; do [ ${#n} -gt $w_name ] && w_name=${#n}; done

# cell WIDTH COLOR TEXT — pad first so ANSI codes don't break alignment
cell() { printf '%s%-*s%s  ' "$2" "$1" "$3" "$C_RST"; }

pct_color() {
  case ${1:-} in ''|*[!0-9]*) printf '%s' "$C_DIM"; return ;; esac
  if [ "$1" -ge 90 ]; then printf '%s' "$C_BAD"
  elif [ "$1" -ge 75 ]; then printf '%s' "$C_WARN"
  fi
}

printf '%s' "$C_BOLD"
cell "$w_name" "" NODE; cell 15 "" ADDRESS; cell 4 "" PING; cell 8 "" "TCP:$PORT"
[ "$LEVEL" -ge 3 ] && cell 7 "" LOGIN
[ "$LEVEL" -ge 4 ] && { cell 16 "" OS; cell 7 "" ARCH; cell 6 "" UP; cell 9 "" LOAD
                        cell 4 "" MEM; cell 4 "" DISK; printf 'GPU'; }
printf '%s\n' "$C_RST"

total=0; good=0
for idx in "${!NAMES[@]}"; do
  f="$TMPDIR_LC/node.$idx"
  total=$((total + 1))
  if [ ! -s "$f" ]; then
    cell "$w_name" "$C_BAD" "${NAMES[$idx]}"; printf '%s(check crashed)%s\n' "$C_BAD" "$C_RST"
    continue
  fi
  IFS='|' read -r name ip ping tcp login os arch up load ncpu mem disk gpu ok <"$f"
  [ "$ok" = 1 ] && good=$((good + 1))

  if [ "$ok" = 1 ]; then c_name=$C_OK; else c_name=$C_BAD; fi
  if [ "$ping" = yes ]; then c_ping=$C_OK
  elif [ "$tcp" = open ]; then c_ping=$C_WARN   # ICMP blocked but host is up
  else c_ping=$C_BAD; fi
  if [ "$tcp" = open ]; then c_tcp=$C_OK; else c_tcp=$C_BAD; fi

  cell "$w_name" "$c_name" "$name"
  cell 15 "" "$ip"
  cell 4 "$c_ping" "$ping"
  cell 8 "$c_tcp" "$tcp"
  if [ "$LEVEL" -ge 3 ]; then
    case $login in ok) c=$C_OK ;; skip) c=$C_DIM ;; *) c=$C_BAD ;; esac
    cell 7 "$c" "$login"
  fi
  if [ "$LEVEL" -ge 4 ]; then
    if [ "$login" = ok ]; then
      load_s=$load; [ "$ncpu" != - ] && load_s="$load/$ncpu"
      mem_s=$mem; [ "$mem" != - ] && mem_s="$mem%"
      disk_s=$disk; [ "$disk" != - ] && disk_s="$disk%"
      cell 16 "" "$(printf '%.16s' "$os")"
      cell 7 "" "$arch"
      cell 6 "" "$(fmt_uptime "$up")"
      cell 9 "" "$load_s"
      cell 4 "$(pct_color "$mem")" "$mem_s"
      cell 4 "$(pct_color "$disk")" "$disk_s"
      printf '%s' "$gpu"
    fi
  fi
  printf '\n'
done

echo
if [ $good -eq $total ]; then c=$C_OK; else c=$C_BAD; fi
printf '%s%d/%d nodes up%s (level %d, timeout %ss)\n' "$c" "$good" "$total" "$C_RST" "$LEVEL" "$TIMEOUT"
[ $good -eq $total ]
