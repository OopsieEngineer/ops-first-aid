#!/usr/bin/env bash
#
# diag.sh v2 - Linux / Docker / Swarm / RabbitMQ / MinIO / Traefik diagnostics
#
# Read-only diagnostics. No service restarts, configuration changes,
# container exec commands, cleanup, or resource modifications.
#
# Usage:
#   ./diag.sh
#   ./diag.sh --quick
#   ./diag.sh --full
#   ./diag.sh --only rabbitmq,minio
#   ./diag.sh --output /tmp/diag.txt
#
# Optional environment variables:
#   RABBITMQ_HOST=localhost
#   RABBITMQ_PORT=15672
#   RABBITMQ_USER=guest
#   RABBITMQ_PASSWORD=guest
#   MINIO_HOST=localhost
#   MINIO_PORT=9000
#   MINIO_CONSOLE_PORT=9001
#   TRAEFIK_HOST=localhost
#   TRAEFIK_PORT=8080
#

set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
HOSTNAME="$(hostname 2>/dev/null || echo unknown)"
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
MODE="normal"
OUTPUT="diag-${HOSTNAME}-${TIMESTAMP}.txt"
ONLY=""
ERROR_COUNT=0

RABBITMQ_HOST="${RABBITMQ_HOST:-localhost}"
RABBITMQ_PORT="${RABBITMQ_PORT:-15672}"
RABBITMQ_USER="${RABBITMQ_USER:-guest}"
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-guest}"

MINIO_HOST="${MINIO_HOST:-localhost}"
MINIO_PORT="${MINIO_PORT:-9000}"
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"

TRAEFIK_HOST="${TRAEFIK_HOST:-localhost}"
TRAEFIK_PORT="${TRAEFIK_PORT:-8080}"

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Linux / Docker / Swarm / RabbitMQ / MinIO / Traefik diagnostic report.

Options:
  -q, --quick              Basic diagnostics only
  -f, --full               More detailed diagnostics and logs
      --only LIST          Run selected checks only
                           system,storage,network,systemd,docker,swarm,
                           rabbitmq,minio,traefik,security
  -o, --output FILE        Write report to FILE
  -h, --help               Show this help

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --quick
  sudo $SCRIPT_NAME --full
  $SCRIPT_NAME --only rabbitmq,minio
  $SCRIPT_NAME --only docker,swarm,rabbitmq
  $SCRIPT_NAME --output /tmp/diag.txt

Optional environment variables:
  RABBITMQ_HOST / RABBITMQ_PORT / RABBITMQ_USER / RABBITMQ_PASSWORD
  MINIO_HOST / MINIO_PORT / MINIO_CONSOLE_PORT
  TRAEFIK_HOST / TRAEFIK_PORT

The script is READ-ONLY. It does not restart services, modify
configuration, remove resources, or execute commands inside containers.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -q|--quick)
            MODE="quick"
            shift
            ;;
        -f|--full)
            MODE="full"
            shift
            ;;
        --only)
            [[ $# -ge 2 ]] || { echo "Error: --only requires a list." >&2; exit 2; }
            ONLY="$2"
            shift 2
            ;;
        -o|--output)
            [[ $# -ge 2 ]] || { echo "Error: --output requires a filename." >&2; exit 2; }
            OUTPUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

OUTPUT_DIR="$(dirname "$OUTPUT")"
if [[ "$OUTPUT_DIR" != "." && ! -d "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR" 2>/dev/null || {
        echo "Error: cannot create output directory: $OUTPUT_DIR" >&2
        exit 1
    }
fi

{
    echo "============================================================"
    echo " Linux / DevOps Diagnostic Report v2"
    echo "============================================================"
    echo "Host       : $HOSTNAME"
    echo "Date       : $(date)"
    echo "User       : $(id -un 2>/dev/null || echo unknown)"
    echo "Mode       : $MODE"
    echo "Checks     : ${ONLY:-all}"
    echo "Script     : $SCRIPT_NAME"
    echo "============================================================"
    echo
} > "$OUTPUT"

section() {
    {
        echo
        echo "------------------------------------------------------------"
        echo " $1"
        echo "------------------------------------------------------------"
    } >> "$OUTPUT"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

enabled() {
    local name="$1"
    [[ -z "$ONLY" ]] && return 0
    IFS=',' read -ra requested <<< "$ONLY"
    for item in "${requested[@]}"; do
        [[ "$item" == "$name" ]] && return 0
    done
    return 1
}

run_cmd() {
    local description="$1"
    shift

    {
        echo
        echo "### $description"
        echo "\$ $*"
    } >> "$OUTPUT"

    if ! "$@" >> "$OUTPUT" 2>&1; then
        echo "[command returned non-zero status]" >> "$OUTPUT"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
}

run_shell() {
    local description="$1"
    local command="$2"

    {
        echo
        echo "### $description"
        echo "\$ $command"
    } >> "$OUTPUT"

    if ! bash -c "$command" >> "$OUTPUT" 2>&1; then
        echo "[command returned non-zero status]" >> "$OUTPUT"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
}

http_check() {
    local name="$1"
    local url="$2"

    echo >> "$OUTPUT"
    echo "### $name" >> "$OUTPUT"
    echo "\$ curl --connect-timeout 3 --max-time 8 $url" >> "$OUTPUT"

    if have_cmd curl; then
        curl --connect-timeout 3 --max-time 8 -sS \
            -o /dev/null \
            -w 'HTTP %{http_code} | time=%{time_total}s | remote=%{remote_ip}\n' \
            "$url" >> "$OUTPUT" 2>&1 || {
                echo "[HTTP check failed]" >> "$OUTPUT"
            }
    else
        echo "curl is not installed; HTTP check skipped." >> "$OUTPUT"
    fi
}

# ------------------------------------------------------------
# SYSTEM
# ------------------------------------------------------------

if enabled system; then
    section "SYSTEM"

    run_cmd "Hostname" hostname
    run_cmd "OS information" bash -c 'cat /etc/os-release 2>/dev/null || true'
    run_cmd "Kernel" uname -a
    run_cmd "Uptime" uptime
    run_cmd "Last boot" bash -c 'who -b 2>/dev/null || true'
    run_cmd "Current date/time" date

    if have_cmd lscpu; then
        run_cmd "CPU information" lscpu
    else
        run_cmd "CPU information" bash -c \
            'grep -E "^(model name|CPU\(s\))" /proc/cpuinfo 2>/dev/null | sort -u || true'
    fi

    run_cmd "Memory" free -h
    have_cmd swapon && run_cmd "Swap" swapon --show
    run_cmd "Load average" bash -c 'cat /proc/loadavg 2>/dev/null || true'

    if [[ "$MODE" == "full" ]]; then
        run_cmd "Top CPU processes" bash -c 'ps aux --sort=-%cpu | head -n 16'
        run_cmd "Top memory processes" bash -c 'ps aux --sort=-%mem | head -n 16'
    else
        run_cmd "Top CPU processes" bash -c 'ps aux --sort=-%cpu | head -n 11'
    fi
fi

# ------------------------------------------------------------
# STORAGE
# ------------------------------------------------------------

if enabled storage; then
    section "STORAGE"

    run_cmd "Filesystem usage" df -hT
    run_cmd "Inode usage" df -ih

    have_cmd lsblk && \
        run_cmd "Block devices" lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS

    have_cmd findmnt && run_cmd "Mounted filesystems" findmnt

    if [[ "$MODE" == "full" ]]; then
        run_cmd "Disk usage: root directories" bash -c \
            'du -xhd1 / 2>/dev/null | sort -h | tail -n 20'
    fi
fi

# ------------------------------------------------------------
# NETWORK
# ------------------------------------------------------------

if enabled network; then
    section "NETWORK"

    have_cmd ip && run_cmd "Network interfaces" ip -brief address
    have_cmd ip && run_cmd "Routes" ip route
    have_cmd ip && run_cmd "IPv6 routes" ip -6 route

    if have_cmd resolvectl; then
        run_cmd "DNS status" resolvectl status
    elif [[ -f /etc/resolv.conf ]]; then
        run_cmd "DNS configuration" cat /etc/resolv.conf
    fi

    have_cmd ss && run_cmd "Listening TCP/UDP ports" ss -tulpen
    have_cmd ip && run_cmd "ARP/neighbour table" ip neigh

    if [[ "$MODE" == "full" ]] && have_cmd ethtool && have_cmd ip; then
        while read -r iface; do
            [[ "$iface" == "lo" ]] && continue
            {
                echo
                echo "### Link information: $iface"
                ethtool "$iface" 2>&1 || true
            } >> "$OUTPUT"
        done < <(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1)
    fi
fi

# ------------------------------------------------------------
# SYSTEMD / LOGS
# ------------------------------------------------------------

if enabled systemd; then
    section "SYSTEMD / LOGS"

    if have_cmd systemctl; then
        run_cmd "Failed systemd services" systemctl --failed --no-pager
        run_cmd "Running services" systemctl list-units --type=service --state=running --no-pager

        if [[ "$MODE" == "full" ]]; then
            run_cmd "Systemd boot time" systemd-analyze
            run_cmd "Systemd blame (top 20)" bash -c \
                'systemd-analyze blame --no-pager | head -n 20'
        fi
    fi

    if have_cmd journalctl; then
        run_cmd "Recent journal errors (last 24h)" \
            journalctl --since "24 hours ago" -p err..alert --no-pager

        run_cmd "Recent kernel errors (last 24h)" \
            journalctl --since "24 hours ago" -k -p err..alert --no-pager

        if [[ "$MODE" == "full" ]]; then
            run_cmd "Recent warnings/errors (last 24h)" \
                journalctl --since "24 hours ago" -p warning..alert --no-pager
        fi
    fi
fi

# ------------------------------------------------------------
# DOCKER
# ------------------------------------------------------------

if enabled docker; then
    section "DOCKER"

    if have_cmd docker; then
        run_cmd "Docker version" docker version
        run_cmd "Docker info" docker info
        run_cmd "Docker disk usage" docker system df
        run_cmd "Docker containers" docker ps -a \
            --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
        run_cmd "Docker images" docker images \
            --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}'
        run_cmd "Docker volumes" docker volume ls
        run_cmd "Docker networks" docker network ls

        if [[ "$MODE" != "quick" ]]; then
            run_cmd "Docker container resource usage" docker stats --no-stream

            mapfile -t CONTAINERS < <(
                docker ps --format '{{.Names}}' 2>/dev/null | head -n 15
            )

            if [[ ${#CONTAINERS[@]} -gt 0 ]]; then
                echo >> "$OUTPUT"
                echo "### Recent Docker logs (last 50 lines/container)" >> "$OUTPUT"

                for container in "${CONTAINERS[@]}"; do
                    echo >> "$OUTPUT"
                    echo "===== $container =====" >> "$OUTPUT"
                    docker logs --tail 50 "$container" >> "$OUTPUT" 2>&1 || true
                done
            fi
        fi
    else
        echo "Docker: not installed or not available in PATH." >> "$OUTPUT"
    fi
fi

# ------------------------------------------------------------
# DOCKER SWARM
# ------------------------------------------------------------

if enabled swarm; then
    section "DOCKER SWARM"

    if have_cmd docker; then
        SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"

        if [[ "$SWARM_STATE" == "active" ]]; then
            run_cmd "Swarm local node state" docker info --format '{{json .Swarm}}'
            run_cmd "Swarm nodes" docker node ls
            run_cmd "Swarm services" docker service ls
            run_cmd "Swarm tasks" docker service ps --no-trunc \
                "$(docker service ls -q 2>/dev/null | head -n 1)" 2>/dev/null || true

            if [[ "$MODE" != "quick" ]]; then
                run_cmd "Swarm node details" bash -c \
                    'docker node ls -q 2>/dev/null | xargs -r -n1 docker node inspect --pretty'

                run_cmd "Swarm service task summary" bash -c \
                    'docker service ls --format "{{.Name}}" | while read -r s; do echo "===== $s ====="; docker service ps --no-trunc "$s"; done'
            fi
        elif [[ "$SWARM_STATE" == "inactive" ]]; then
            echo "Docker Swarm: available but this node is not part of an active swarm." >> "$OUTPUT"
        else
            echo "Docker Swarm: unavailable or Docker is not accessible." >> "$OUTPUT"
        fi
    else
        echo "Docker: not available; Swarm check skipped." >> "$OUTPUT"
    fi
fi

# ------------------------------------------------------------
# RABBITMQ
# ------------------------------------------------------------

if enabled rabbitmq; then
    section "RABBITMQ"

    RABBIT_FOUND="false"

    if have_cmd rabbitmq-diagnostics; then
        RABBIT_FOUND="true"
        run_cmd "RabbitMQ diagnostics ping" rabbitmq-diagnostics -q ping
        run_cmd "RabbitMQ node health" rabbitmq-diagnostics -q status
        run_cmd "RabbitMQ alarms" rabbitmq-diagnostics alarms
        run_cmd "RabbitMQ listeners" rabbitmq-diagnostics listeners

        if [[ "$MODE" != "quick" ]]; then
            run_cmd "RabbitMQ cluster status" rabbitmq-diagnostics cluster_status
            run_cmd "RabbitMQ memory breakdown" rabbitmq-diagnostics memory_breakdown
            run_cmd "RabbitMQ environment" rabbitmq-diagnostics environment
        fi
    elif have_cmd rabbitmqctl; then
        RABBIT_FOUND="true"
        run_cmd "RabbitMQ status" rabbitmqctl status
        run_cmd "RabbitMQ alarms" rabbitmqctl list_alarms
        run_cmd "RabbitMQ listeners" rabbitmqctl listeners
        run_cmd "RabbitMQ cluster status" rabbitmqctl cluster_status

        if [[ "$MODE" != "quick" ]]; then
            run_cmd "RabbitMQ queues" rabbitmqctl list_queues \
                name messages messages_ready messages_unacknowledged consumers
            run_cmd "RabbitMQ connections" rabbitmqctl list_connections
            run_cmd "RabbitMQ channels" rabbitmqctl list_channels
        fi
    fi

    # Management API check. Password is never printed.
    if have_cmd curl; then
        echo >> "$OUTPUT"
        echo "### RabbitMQ Management API" >> "$OUTPUT"
        echo "\$ curl http://${RABBITMQ_HOST}:${RABBITMQ_PORT}/api/overview" >> "$OUTPUT"

        CURL_AUTH=""
        if [[ -n "$RABBITMQ_USER" && -n "$RABBITMQ_PASSWORD" ]]; then
            CURL_AUTH="-u ${RABBITMQ_USER}:********"
        fi

        # Credentials are passed only to curl and are not echoed.
        if curl --connect-timeout 3 --max-time 8 -fsS \
            -u "${RABBITMQ_USER}:${RABBITMQ_PASSWORD}" \
            "http://${RABBITMQ_HOST}:${RABBITMQ_PORT}/api/overview" \
            -o /tmp/diag-rabbitmq-overview.$$ 2>>"$OUTPUT"; then
            echo "Management API: reachable" >> "$OUTPUT"
            if have_cmd python3; then
                python3 - "$OUTPUT" /tmp/diag-rabbitmq-overview.$$ <<'PY'
import json
import sys
out, fn = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(fn, encoding="utf-8"))
    with open(out, "a", encoding="utf-8") as f:
        print(f"Cluster name : {data.get('cluster_name', 'n/a')}", file=f)
        print(f"RabbitMQ     : {data.get('rabbitmq_version', 'n/a')}", file=f)
        print(f"Erlang       : {data.get('erlang_version', 'n/a')}", file=f)
        print(f"Node         : {data.get('node', 'n/a')}", file=f)
        print(f"Object totals: {data.get('object_totals', {})}", file=f)
except Exception:
    pass
PY
            fi
        else
            echo "Management API: not reachable with configured credentials." >> "$OUTPUT"
        fi
        rm -f /tmp/diag-rabbitmq-overview.$$ 2>/dev/null || true
    fi

    # Docker-specific RabbitMQ discovery without entering the container.
    if have_cmd docker; then
        mapfile -t RABBIT_CONTAINERS < <(
            docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null |
            awk 'BEGIN{IGNORECASE=1} /rabbitmq/ {print $1}'
        )

        if [[ ${#RABBIT_CONTAINERS[@]} -gt 0 ]]; then
            echo >> "$OUTPUT"
            echo "### RabbitMQ Docker containers" >> "$OUTPUT"
            for item in "${RABBIT_CONTAINERS[@]}"; do
                name="${item%%$'\t'*}"
                image="${item#*$'\t'}"
                echo "$name | $image" >> "$OUTPUT"
                docker inspect --format \
                    'Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}} RestartCount={{.RestartCount}}' \
                    "$name" >> "$OUTPUT" 2>&1 || true

                if [[ "$MODE" != "quick" ]]; then
                    echo "--- recent logs ---" >> "$OUTPUT"
                    docker logs --tail 100 "$name" >> "$OUTPUT" 2>&1 || true
                fi
            done
            RABBIT_FOUND="true"
        fi
    fi

    if [[ "$RABBIT_FOUND" == "false" ]]; then
        echo "RabbitMQ: no local CLI or RabbitMQ container detected." >> "$OUTPUT"
        echo "For a remote broker, set RABBITMQ_HOST/PORT and use the Management API." >> "$OUTPUT"
    fi
fi

# ------------------------------------------------------------
# MINIO
# ------------------------------------------------------------

if enabled minio; then
    section "MINIO"

    MINIO_FOUND="false"

    if have_cmd mc; then
        MINIO_FOUND="true"
        run_cmd "MinIO client version" mc --version

        # Only inspect configured aliases; do not create aliases.
        if [[ -n "${MINIO_ALIAS:-}" ]]; then
            run_cmd "MinIO alias info" mc admin info "$MINIO_ALIAS"
            run_cmd "MinIO server health" mc admin info "$MINIO_ALIAS" --json
        else
            echo "MinIO client found, but MINIO_ALIAS is not set; no alias will be created." >> "$OUTPUT"
        fi
    fi

    if have_cmd curl; then
        http_check "MinIO liveness" "http://${MINIO_HOST}:${MINIO_PORT}/minio/health/live"
        http_check "MinIO readiness" "http://${MINIO_HOST}:${MINIO_PORT}/minio/health/ready"
        MINIO_FOUND="true"
    fi

    if have_cmd docker; then
        mapfile -t MINIO_CONTAINERS < <(
            docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null |
            awk 'BEGIN{IGNORECASE=1} /minio/ {print $1}'
        )

        if [[ ${#MINIO_CONTAINERS[@]} -gt 0 ]]; then
            echo >> "$OUTPUT"
            echo "### MinIO Docker containers" >> "$OUTPUT"

            for item in "${MINIO_CONTAINERS[@]}"; do
                name="${item%%$'\t'*}"
                image="${item#*$'\t'}"
                echo "$name | $image" >> "$OUTPUT"

                docker inspect --format \
                    'Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}} RestartCount={{.RestartCount}}' \
                    "$name" >> "$OUTPUT" 2>&1 || true

                if [[ "$MODE" != "quick" ]]; then
                    echo "--- recent logs ---" >> "$OUTPUT"
                    docker logs --tail 100 "$name" >> "$OUTPUT" 2>&1 || true
                fi
            done
            MINIO_FOUND="true"
        fi
    fi

    if [[ "$MINIO_FOUND" == "false" ]]; then
        echo "MinIO: no local client, endpoint, or MinIO container detected." >> "$OUTPUT"
    fi
fi

# ------------------------------------------------------------
# TRAEFIK
# ------------------------------------------------------------

if enabled traefik; then
    section "TRAEFIK"

    TRAEFIK_FOUND="false"

    if have_cmd docker; then
        mapfile -t TRAEFIK_CONTAINERS < <(
            docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null |
            awk 'BEGIN{IGNORECASE=1} /traefik/ {print $1}'
        )

        if [[ ${#TRAEFIK_CONTAINERS[@]} -gt 0 ]]; then
            TRAEFIK_FOUND="true"
            echo "### Traefik Docker containers" >> "$OUTPUT"

            for item in "${TRAEFIK_CONTAINERS[@]}"; do
                name="${item%%$'\t'*}"
                image="${item#*$'\t'}"
                echo >> "$OUTPUT"
                echo "===== $name =====" >> "$OUTPUT"
                echo "Image: $image" >> "$OUTPUT"

                docker inspect --format \
                    'Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}} RestartCount={{.RestartCount}}' \
                    "$name" >> "$OUTPUT" 2>&1 || true

                echo "--- published ports ---" >> "$OUTPUT"
                docker port "$name" >> "$OUTPUT" 2>&1 || true

                if [[ "$MODE" != "quick" ]]; then
                    echo "--- recent logs ---" >> "$OUTPUT"
                    docker logs --tail 100 "$name" >> "$OUTPUT" 2>&1 || true
                fi
            done
        fi
    fi

    if have_cmd curl; then
        # Traefik's dashboard/API is often disabled or bound elsewhere,
        # so a failed check is informational rather than a configuration change.
        http_check "Traefik API/dashboard endpoint" \
            "http://${TRAEFIK_HOST}:${TRAEFIK_PORT}/api/version"

        TRAEFIK_FOUND="true"
    fi

    if [[ "$TRAEFIK_FOUND" == "false" ]]; then
        echo "Traefik: no local container or endpoint check available." >> "$OUTPUT"
    fi
fi

# ------------------------------------------------------------
# SECURITY / ENVIRONMENT
# ------------------------------------------------------------

if enabled security; then
    section "BASIC SECURITY / ENVIRONMENT"

    have_cmd ufw && run_cmd "UFW status" ufw status verbose
    have_cmd sestatus && run_cmd "SELinux status" sestatus
    have_cmd aa-status && run_cmd "AppArmor status" aa-status

    run_cmd "Environment (safe subset)" bash -c \
        'printf "PATH=%s\nHOME=%s\nSHELL=%s\nLANG=%s\n" "$PATH" "$HOME" "${SHELL:-}" "${LANG:-}"'
fi

# ------------------------------------------------------------
# SUMMARY
# ------------------------------------------------------------

section "QUICK HEALTH SUMMARY"

{
    echo "Generated: $(date)"
    echo

    if have_cmd systemctl && enabled systemd; then
        failed_services="$(systemctl --failed --no-legend --plain 2>/dev/null | grep -c . || true)"
        echo "Failed systemd services : $failed_services"
    fi

    root_usage="$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    [[ -n "${root_usage:-}" ]] && echo "Root filesystem usage   : ${root_usage}%"

    mem_usage="$(free 2>/dev/null | awk '/^Mem:/ {printf "%.0f", ($3/$2)*100}')"
    [[ -n "${mem_usage:-}" ]] && echo "Memory usage             : ${mem_usage}%"

    if have_cmd docker; then
        running="$(docker ps -q 2>/dev/null | wc -l)"
        total="$(docker ps -aq 2>/dev/null | wc -l)"
        echo "Docker containers        : $running running / $total total"
    else
        echo "Docker                   : not available"
    fi

    if have_cmd docker; then
        swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
        [[ -n "$swarm_state" ]] && echo "Docker Swarm             : $swarm_state"
    fi

    if have_cmd rabbitmq-diagnostics; then
        echo "RabbitMQ CLI             : available"
    elif have_cmd rabbitmqctl; then
        echo "RabbitMQ CLI             : available"
    else
        echo "RabbitMQ CLI             : not installed"
    fi

    if have_cmd mc; then
        echo "MinIO client (mc)        : available"
    else
        echo "MinIO client (mc)        : not installed"
    fi

    if have_cmd curl; then
        echo "HTTP checks              : available"
    else
        echo "HTTP checks              : curl not installed"
    fi
} >> "$OUTPUT"

{
    echo
    echo "============================================================"
    echo " Report complete"
    echo "============================================================"
    echo "Output : $OUTPUT"
    echo "Errors : $ERROR_COUNT command(s) returned non-zero status"
    echo
    echo "READ-ONLY: No services, containers, configuration, files,"
    echo "           Docker resources, RabbitMQ state, or MinIO data"
    echo "           were intentionally modified by this script."
    echo
    echo "NOTE: Non-zero command status can be expected when a command"
    echo "      requires root privileges or a component is unavailable."
    echo "============================================================"
} >> "$OUTPUT"

cat "$OUTPUT"

echo
echo "Report saved to: $OUTPUT"
