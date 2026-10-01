#!/usr/bin/env bash
#
# cert-expiry-check.sh - Report the notAfter date of TLS certificates
#
# Checks certificate files on disk and/or live TLS endpoints and reports
# the expiry date and remaining days.
#
# Usage:
#   ./cert-expiry-check.sh /etc/ssl/certs/app.crt
#   ./cert-expiry-check.sh --host example.com
#   ./cert-expiry-check.sh --host rabbitmq.local:5671 --warn 45 --crit 14
#   ./cert-expiry-check.sh --dir /etc/ssl/certs --quiet
#
# Exit codes:
#   0  all certificates OK
#   1  at least one certificate within the warning threshold
#   2  at least one certificate within the critical threshold or expired
#   3  usage or runtime error
#

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"

WARN_DAYS=30
CRIT_DAYS=7
TIMEOUT=10
QUIET=0
TARGETS=()
WORST=0

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] [CERT_FILE...]

Report the notAfter (expiry) date of TLS certificates.

Targets:
  CERT_FILE                PEM or DER certificate file
      --host HOST[:PORT]   Live TLS endpoint, default port 443. Repeatable.
      --dir DIR            Check every *.crt / *.pem file in DIR

Options:
  -w, --warn N             Warning threshold in days, default $WARN_DAYS
  -c, --crit N             Critical threshold in days, default $CRIT_DAYS
  -t, --timeout N          Connection timeout in seconds, default $TIMEOUT
  -q, --quiet              Print only WARN, CRITICAL and ERROR lines
      --help               Show this help

Exit codes: 0 OK, 1 WARN, 2 CRITICAL, 3 error
EOF
}

die() {
    echo "$SCRIPT_NAME: $*" >&2
    exit 3
}

worst() {
    (( $1 > WORST )) && WORST="$1"
    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            [[ $# -ge 2 ]] || die "missing value for $1"
            TARGETS+=("host:$2"); shift 2 ;;
        --dir)
            [[ $# -ge 2 ]] || die "missing value for $1"
            [[ -d "$2" ]] || die "not a directory: $2"
            while IFS= read -r f; do
                TARGETS+=("file:$f")
            done < <(find "$2" -maxdepth 1 -type f \( -name '*.crt' -o -name '*.pem' \) | sort)
            shift 2 ;;
        -w|--warn)
            [[ $# -ge 2 ]] || die "missing value for $1"
            WARN_DAYS="$2"; shift 2 ;;
        -c|--crit)
            [[ $# -ge 2 ]] || die "missing value for $1"
            CRIT_DAYS="$2"; shift 2 ;;
        -t|--timeout)
            [[ $# -ge 2 ]] || die "missing value for $1"
            TIMEOUT="$2"; shift 2 ;;
        -q|--quiet)
            QUIET=1; shift ;;
        --help)
            usage; exit 0 ;;
        -*)
            usage >&2
            die "unknown option: $1" ;;
        *)
            TARGETS+=("file:$1"); shift ;;
    esac
done

command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

[[ "$WARN_DAYS" =~ ^[0-9]+$ ]] || die "--warn must be a positive integer"
[[ "$CRIT_DAYS" =~ ^[0-9]+$ ]] || die "--crit must be a positive integer"
[[ "$TIMEOUT"   =~ ^[0-9]+$ ]] || die "--timeout must be a positive integer"
(( CRIT_DAYS <= WARN_DAYS )) || die "--crit must not be greater than --warn"
(( ${#TARGETS[@]} > 0 )) || { usage >&2; die "no targets given"; }

report() {
    local label="$1" not_after="$2"
    local expiry_epoch now_epoch days status

    expiry_epoch="$(date -d "$not_after" +%s 2>/dev/null)" || {
        printf 'ERROR    %-40s unparsable notAfter: %s\n' "$label" "$not_after" >&2
        worst 3
        return
    }
    now_epoch="$(date +%s)"
    days=$(( (expiry_epoch - now_epoch) / 86400 ))

    if (( days < 0 )); then
        status="EXPIRED"
        worst 2
    elif (( days <= CRIT_DAYS )); then
        status="CRITICAL"
        worst 2
    elif (( days <= WARN_DAYS )); then
        status="WARN"
        worst 1
    else
        status="OK"
    fi

    if (( QUIET == 1 )) && [[ "$status" == "OK" ]]; then
        return
    fi

    printf '%-8s %-40s notAfter=%s (%s days)\n' \
        "$status" "$label" "$(date -d "$not_after" '+%Y-%m-%d %H:%M:%S %Z')" "$days"
}

check_file() {
    local path="$1" not_after

    if [[ ! -r "$path" ]]; then
        printf 'ERROR    %-40s not readable\n' "$path" >&2
        worst 3
        return
    fi

    not_after="$(openssl x509 -in "$path" -noout -enddate 2>/dev/null)" \
        || not_after="$(openssl x509 -in "$path" -inform DER -noout -enddate 2>/dev/null)"

    if [[ -z "$not_after" ]]; then
        printf 'ERROR    %-40s not a valid certificate\n' "$path" >&2
        worst 3
        return
    fi

    report "$path" "${not_after#notAfter=}"
}

check_host() {
    local target="$1" host port pem not_after
    host="${target%:*}"
    port="${target##*:}"
    if [[ "$target" != *:* ]]; then
        host="$target"
        port=443
    fi

    pem="$(echo | timeout "$TIMEOUT" openssl s_client \
        -connect "${host}:${port}" -servername "$host" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null)"

    if [[ -z "$pem" ]]; then
        printf 'ERROR    %-40s TLS handshake failed\n' "${host}:${port}" >&2
        worst 3
        return
    fi

    not_after="${pem#notAfter=}"
    report "${host}:${port}" "$not_after"
}

for target in "${TARGETS[@]}"; do
    case "$target" in
        file:*) check_file "${target#file:}" ;;
        host:*) check_host "${target#host:}" ;;
    esac
done

exit "$WORST"
