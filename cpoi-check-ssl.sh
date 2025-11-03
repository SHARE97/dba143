#!/bin/bash
set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Variables par défaut
VERBOSE=true
PORT=""
DATA_DIR=""
JSON_OUTPUT=false

# Affichage de l'aide
usage() {
    echo -e "Usage: $0 [-v|-q] [-p port] [-d data_directory] [-j]"
    echo -e "  -v : mode verbeux (par défaut)"
    echo -e "  -q : mode silencieux"
    echo -e "  -p : port PostgreSQL personnalisé"
    echo -e "  -d : répertoire de données PostgreSQL"
    echo -e "  -j : sortie JSON"
    echo -e "  -h : afficher l'aide"
    exit 0
}

# Lecture des options
while getopts ":vqp:d:jh" opt; do
    case $opt in
        v) VERBOSE=true ;;
        q) VERBOSE=false ;;
        p) PORT="$OPTARG" ;;
        d) DATA_DIR="$OPTARG" ;;
        j) JSON_OUTPUT=true ;;
        h) usage ;;
        \?) echo -e "${RED}Option invalide: -$OPTARG${NC}"; usage ;;
        :) echo -e "${RED}Option -$OPTARG requiert un argument.${NC}"; usage ;;
    esac
done

log() { $VERBOSE && echo -e "$1"; }

check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}Ce script nécessite les droits root${NC}" && exit 1
}

find_postgres_instance() {
    local port="" data_dir=""
    pg_process=$(ps aux | grep '[p]ostgres' | head -n1)
    [[ "$pg_process" =~ -p[[:space:]]*([0-9]+) ]] && port="${BASH_REMATCH[1]}"
    [[ "$pg_process" =~ -D[[:space:]]*([^[:space:]]+) ]] && data_dir="${BASH_REMATCH[1]}"
    [[ -z "$port" && $(pg_isready -p 5432 >/dev/null 2>&1) ]] && port="5432"
    [[ -z "$port" && $(psql -l >/dev/null 2>&1) ]] && port="socket"
    [[ -z "$data_dir" ]] && for dir in /var/lib/postgresql/*/main /var/lib/pgsql/*/data /usr/local/var/postgres /opt/homebrew/var/postgres; do
        [[ -d "$dir" && -f "$dir/postgresql.conf" ]] && data_dir="$dir" && break
    done
    echo "$port:$data_dir"
}

check_ssl_usage() {
    local port="$1"
    [[ "$port" == "socket" ]] && psql -d postgres -c "SHOW ssl;" -t -A 2>/dev/null || psql -h localhost -p "$port" -d postgres -c "SHOW ssl;" -t -A 2>/dev/null
}

get_certificate_info() {
    local data_dir="$1"
    local cert_path="" subject="" issuer="" serial="" not_before="" not_after="" days_remaining=""

    conf="$data_dir/postgresql.conf"
    if [[ -f "$conf" ]]; then
        ssl_cert_file=$(grep -E "^ssl_cert_file" "$conf" | cut -d= -f2 | tr -d " ';\"")
        [[ "$ssl_cert_file" != /* ]] && ssl_cert_file="$data_dir/$ssl_cert_file"
        [[ -f "$ssl_cert_file" ]] && cert_path="$ssl_cert_file"
    fi

    [[ -z "$cert_path" ]] && for file in "$data_dir/server.crt" /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/postgresql/*/main/server.crt; do
        [[ -f "$file" ]] && cert_path="$file" && break
    done

    if [[ -n "$cert_path" ]]; then
        subject=$(openssl x509 -in "$cert_path" -noout -subject | cut -d= -f2-)
        issuer=$(openssl x509 -in "$cert_path" -noout -issuer | cut -d= -f2-)
        serial=$(openssl x509 -in "$cert_path" -noout -serial | cut -d= -f2)
        not_before=$(openssl x509 -in "$cert_path" -noout -startdate | cut -d= -f2)
        not_after=$(openssl x509 -in "$cert_path" -noout -enddate | cut -d= -f2)
        current_time=$(date +%s)
        not_after_epoch=$(date -d "$not_after" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null)
        [[ -n "$not_after_epoch" ]] && days_remaining=$(( (not_after_epoch - current_time) / 86400 ))
    fi

    echo "$cert_path|$subject|$issuer|$serial|$not_before|$not_after|$days_remaining"
}

output_json() {
    local ssl="$1" cert="$2"
    IFS='|' read -r cert_path subject issuer serial not_before not_after days_remaining <<< "$cert"
    hostname=$(hostname)
    collection_date=$(date -Iseconds)

    jq -n \
        --arg hostname "$hostname" \
        --arg collected_at "$collection_date" \
        --arg port "$PORT" \
        --arg data_dir "$DATA_DIR" \
        --arg ssl "$ssl" \
        --arg cert_path "$cert_path" \
        --arg subject "$subject" \
        --arg issuer "$issuer" \
        --arg serial "$serial" \
        --arg not_before "$not_before" \
        --arg not_after "$not_after" \
        --arg days_remaining "${days_remaining:-0}" \
        '{
            hostname: $hostname,
            collected_at: $collected_at,
            port: $port,
            data_directory: $data_dir,
            ssl_enabled: ($ssl == "on"),
            certificate: {
                path: $cert_path,
                subject: $subject,
                issuer: $issuer,
                serial: $serial,
                valid_from: $not_before,
                valid_to: $not_after,
                days_remaining: ($days_remaining | tonumber)
            }
        }'
}

main() {
    log "${GREEN}=== Vérificateur SSL PostgreSQL ===${NC}"
    [[ -z "$PORT" || -z "$DATA_DIR" ]] && IFS=':' read -r PORT DATA_DIR <<< "$(find_postgres_instance)"
    log "${GREEN}Instance détectée:${NC}\nPort: $PORT\nRépertoire: $DATA_DIR"

    ssl_status=$(check_ssl_usage "$PORT")
    if [[ "$ssl_status" == "on" ]]; then
        check_root
        cert_info=$(get_certificate_info "$DATA_DIR")
        $JSON_OUTPUT && output_json "$ssl_status" "$cert_info" || {
            echo -e "${GREEN}SSL est activé${NC}"
            IFS='|' read -r cert_path subject issuer serial not_before not_after days_remaining <<< "$cert_info"
            echo -e "${YELLOW}Certificat: $cert_path${NC}"
            echo -e "Sujet: $subject\nÉmetteur: $issuer\nNuméro de série: $serial"
            echo -e "Valide du: $not_before au: $not_after"
            echo -e "${GREEN}Jours restants: $days_remaining${NC}"
        }
    else
        $JSON_OUTPUT && output_json "$ssl_status" "" || echo -e "${YELLOW}SSL n'est pas activé${NC}"
    fi
    log "${GREEN}=== Fin ===${NC}"
}

trap 'echo -e "${RED}Erreur lors de l\'exécution${NC}"; exit 1' ERR
main

