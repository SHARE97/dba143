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

# Configuration pour connexion PostgreSQL sans mot de passe
export PGHOST=localhost
export PGUSER=postgres
export PGDATABASE=postgres

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

log() { 
    if $VERBOSE; then
        echo -e "$1"
    fi
}

# Vérification des dépendances
check_dependencies() {
    local missing_deps=()
    
    command -v psql >/dev/null 2>&1 || missing_deps+=("psql")
    command -v openssl >/dev/null 2>&1 || missing_deps+=("openssl")
    
    if $JSON_OUTPUT; then
        command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${RED}Dépendances manquantes: ${missing_deps[*]}${NC}"
        exit 1
    fi
}

# Vérification des droits root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Ce script nécessite les droits root${NC}"
        exit 1
    fi
}

# Vérification de la connectivité PostgreSQL
check_postgres_connectivity() {
    local port="$1"
    local connect_cmd=""
    
    if [[ "$port" == "socket" || -z "$port" ]]; then
        connect_cmd="psql -d postgres -c \"SELECT 1;\" -t -A >/dev/null 2>&1"
    else
        connect_cmd="psql -h localhost -p \"$port\" -d postgres -c \"SELECT 1;\" -t -A >/dev/null 2>&1"
    fi
    
    if ! eval "$connect_cmd"; then
        echo -e "${RED}Impossible de se connecter à PostgreSQL${NC}"
        echo -e "${YELLOW}Assurez-vous que:${NC}"
        echo -e "  - PostgreSQL est démarré"
        echo -e "  - La connexion sans mot de passe est configurée"
        echo -e "  - L'utilisateur root a les droits nécessaires"
        echo -e "  - Le port spécifié ($port) est correct"
        exit 1
    fi
}

# Récupération du nom du serveur
get_system_info() {
    hostname=$(hostname -f 2>/dev/null || hostname)
    echo "$hostname"
}

# Recherche de l'instance PostgreSQL
find_postgres_instance() {
    local port="" data_dir=""
    
    # Recherche via les processus
    pg_process=$(ps aux | grep '[p]ostgres' | head -n1)
    [[ "$pg_process" =~ -p[[:space:]]*([0-9]+) ]] && port="${BASH_REMATCH[1]}"
    [[ "$pg_process" =~ -D[[:space:]]*([^[:space:]]+) ]] && data_dir="${BASH_REMATCH[1]}"
    
    # Vérification des ports communs
    if [[ -z "$port" ]]; then
        for test_port in 5432 5433 5434; do
            if pg_isready -p "$test_port" >/dev/null 2>&1; then
                port="$test_port"
                break
            fi
        done
    fi
    
    # Vérification de la connexion socket
    if [[ -z "$port" ]] && psql -l >/dev/null 2>&1; then
        port="socket"
    fi
    
    # Recherche du répertoire de données
    if [[ -z "$data_dir" ]]; then
        for dir in /var/lib/postgresql/*/main \
                   /var/lib/pgsql/*/data \
                   /usr/local/var/postgres \
                   /opt/homebrew/var/postgres \
                   /db/data /data/postgres; do
            if [[ -d "$dir" && -f "$dir/postgresql.conf" ]]; then
                data_dir="$dir"
                break
            fi
        done
    fi
    
    echo "$port:$data_dir"
}

# Récupération du nom de l'instance PostgreSQL
get_postgres_instance_name() {
    local port="$1"
    local instance_name=""
    
    if [[ "$port" == "socket" || -z "$port" ]]; then
        instance_name=$(psql -d postgres -c "
            SELECT COALESCE(
                (SELECT setting FROM pg_settings WHERE name = 'cluster_name'),
                'primary'
            );" -t -A 2>/dev/null || echo "primary")
    else
        instance_name=$(psql -h localhost -p "$port" -d postgres -c "
            SELECT COALESCE(
                (SELECT setting FROM pg_settings WHERE name = 'cluster_name'),
                'primary'
            );" -t -A 2>/dev/null || echo "primary")
    fi
    
    echo "$instance_name"
}

# Vérification de l'utilisation SSL
check_ssl_usage() {
    local port="$1"
    
    if [[ "$port" == "socket" || -z "$port" ]]; then
        psql -d postgres -c "SHOW ssl;" -t -A 2>/dev/null || echo "off"
    else
        psql -h localhost -p "$port" -d postgres -c "SHOW ssl;" -t -A 2>/dev/null || echo "off"
    fi
}

# Récupération de la configuration SSL détaillée
get_ssl_configuration() {
    local port="$1"
    local ssl_config=""
    
    if [[ "$port" == "socket" || -z "$port" ]]; then
        ssl_config=$(psql -d postgres -c "
            SELECT 
                name, 
                setting, 
                COALESCE(unit, ''),
                context
            FROM pg_settings 
            WHERE name LIKE '%ssl%' 
               OR name LIKE '%tls%'
               OR name = 'require_ssl'
            ORDER BY name;" -t -A 2>/dev/null | tr '\n' ';')
    else
        ssl_config=$(psql -h localhost -p "$port" -d postgres -c "
            SELECT 
                name, 
                setting, 
                COALESCE(unit, ''),
                context
            FROM pg_settings 
            WHERE name LIKE '%ssl%' 
               OR name LIKE '%tls%'
               OR name = 'require_ssl'
            ORDER BY name;" -t -A 2>/dev/null | tr '\n' ';')
    fi
    
    echo "$ssl_config"
}

# Récupération des informations du certificat
get_certificate_info() {
    local data_dir="$1"
    local cert_path="" subject="" issuer="" serial="" not_before="" not_after="" days_remaining=""

    # Recherche du certificat dans la configuration
    if [[ -f "$data_dir/postgresql.conf" ]]; then
        ssl_cert_file=$(grep -E "^ssl_cert_file" "$data_dir/postgresql.conf" | cut -d= -f2 | tr -d " ';\"")
        if [[ -n "$ssl_cert_file" ]]; then
            if [[ "$ssl_cert_file" != /* ]]; then
                ssl_cert_file="$data_dir/$ssl_cert_file"
            fi
            [[ -f "$ssl_cert_file" ]] && cert_path="$ssl_cert_file"
        fi
    fi

    # Recherche dans les emplacements par défaut
    if [[ -z "$cert_path" ]]; then
        for file in "$data_dir/server.crt" \
                   "$data_dir/ssl/server.crt" \
                   "/etc/ssl/certs/ssl-cert-snakeoil.pem" \
                   "/etc/postgresql/*/main/server.crt" \
                   "/var/lib/pgsql/*/data/server.crt"; do
            for f in $file; do
                if [[ -f "$f" ]]; then
                    cert_path="$f"
                    break 2
                fi
            done
        done
    fi

    # Extraction des informations du certificat
    if [[ -n "$cert_path" && -f "$cert_path" ]]; then
        subject=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//' || echo "")
        issuer=$(openssl x509 -in "$cert_path" -noout -issuer 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//' || echo "")
        serial=$(openssl x509 -in "$cert_path" -noout -serial 2>/dev/null | cut -d= -f2 | sed 's/^[[:space:]]*//' || echo "")
        not_before=$(openssl x509 -in "$cert_path" -noout -startdate 2>/dev/null | cut -d= -f2 | sed 's/^[[:space:]]*//' || echo "")
        not_after=$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2 | sed 's/^[[:space:]]*//' || echo "")
        
        # Calcul des jours restants
        if command -v date >/dev/null 2>&1; then
            current_time=$(date +%s)
            if [[ "$(uname)" == "Linux" ]]; then
                not_after_epoch=$(date -d "$not_after" +%s 2>/dev/null || echo "")
            else
                not_after_epoch=$(date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || echo "")
            fi
            
            if [[ -n "$not_after_epoch" && "$not_after_epoch" -gt "$current_time" ]]; then
                days_remaining=$(( (not_after_epoch - current_time) / 86400 ))
            else
                days_remaining=0
            fi
        fi
    fi

    echo "$cert_path|$subject|$issuer|$serial|$not_before|$not_after|$days_remaining"
}

# Sortie JSON
output_json() {
    local server_name="$1" instance_name="$2" ssl="$3" ssl_config="$4" cert="$5"
    IFS='|' read -r cert_path subject issuer serial not_before not_after days_remaining <<< "$cert"
    
    # Parse SSL configuration
    declare -A ssl_settings
    IFS=';' read -ra CONFIGS <<< "$ssl_config"
    for config in "${CONFIGS[@]}"; do
        if [[ -n "$config" ]]; then
            IFS='|' read -r name setting unit context <<< "$config"
            ssl_settings["$name"]="$setting"
        fi
    done

    jq -n \
        --arg hostname "$server_name" \
        --arg instance "$instance_name" \
        --arg collected_at "$(date -Iseconds)" \
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
        --arg ssl_ciphers "${ssl_settings[ssl_ciphers]:-}" \
        --arg ssl_min_protocol_version "${ssl_settings[ssl_min_protocol_version]:-}" \
        --arg ssl_max_protocol_version "${ssl_settings[ssl_max_protocol_version]:-}" \
        --arg require_ssl "${ssl_settings[require_ssl]:-}" \
        '{
            server_name: $hostname,
            postgres_instance: $instance,
            collected_at: $collected_at,
            connection: {
                port: $port,
                data_directory: $data_dir
            },
            ssl: {
                enabled: ($ssl == "on"),
                configuration: {
                    ssl_ciphers: $ssl_ciphers,
                    ssl_min_protocol_version: $ssl_min_protocol_version,
                    ssl_max_protocol_version: $ssl_max_protocol_version,
                    require_ssl: $require_ssl
                },
                certificate: {
                    path: $cert_path,
                    subject: $subject,
                    issuer: $issuer,
                    serial: $serial,
                    valid_from: $not_before,
                    valid_to: $not_after,
                    days_remaining: ($days_remaining | tonumber)
                }
            }
        }'
}

# Fonction principale
main() {
    log "${GREEN}=== Vérificateur SSL PostgreSQL ===${NC}"
    
    # Vérification des dépendances
    check_dependencies
    
    # Vérification des droits root
    check_root
    
    # Récupération info système
    SERVER_NAME=$(get_system_info)
    log "${GREEN}Serveur: $SERVER_NAME${NC}"
    
    # Détection instance PostgreSQL
    if [[ -z "$PORT" || -z "$DATA_DIR" ]]; then
        log "${YELLOW}Détection automatique de l'instance PostgreSQL...${NC}"
        IFS=':' read -r PORT DATA_DIR <<< "$(find_postgres_instance)"
    fi
    
    # Vérification de la connectivité
    log "${YELLOW}Vérification de la connectivité PostgreSQL...${NC}"
    check_postgres_connectivity "$PORT"
    
    # Nom de l'instance
    INSTANCE_NAME=$(get_postgres_instance_name "$PORT")
    
    log "${GREEN}Instance PostgreSQL détectée:${NC}"
    log "  - Serveur: $SERVER_NAME"
    log "  - Instance: $INSTANCE_NAME"
    log "  - Port: $PORT"
    log "  - Répertoire de données: $DATA_DIR"
    
    # Statut SSL
    log "${YELLOW}Vérification de la configuration SSL...${NC}"
    ssl_status=$(check_ssl_usage "$PORT")
    
    # Configuration SSL détaillée
    ssl_config=$(get_ssl_configuration "$PORT")
    
    if [[ "$ssl_status" == "on" ]]; then
        cert_info=$(get_certificate_info "$DATA_DIR")
        
        if $JSON_OUTPUT; then
            output_json "$SERVER_NAME" "$INSTANCE_NAME" "$ssl_status" "$ssl_config" "$cert_info"
        else
            echo -e "${GREEN}✓ SSL est ACTIVÉ${NC}"
            echo -e "\n${YELLOW}Configuration SSL détaillée:${NC}"
            
            IFS=';' read -ra CONFIGS <<< "$ssl_config"
            for config in "${CONFIGS[@]}"; do
                if [[ -n "$config" ]]; then
                    IFS='|' read -r name setting unit context <<< "$config"
                    echo -e "  - $name: $setting $unit ($context)"
                fi
            done
            
            IFS='|' read -r cert_path subject issuer serial not_before not_after days_remaining <<< "$cert_info"
            
            if [[ -n "$cert_path" ]]; then
                echo -e "\n${YELLOW}Informations du certificat:${NC}"
                echo -e "  - Chemin: $cert_path"
                echo -e "  - Sujet: $subject"
                echo -e "  - Émetteur: $issuer"
                echo -e "  - Numéro de série: $serial"
                echo -e "  - Valide du: $not_before"
                echo -e "  - Valide jusqu'au: $not_after"
                
                if [[ "$days_remaining" -gt 0 ]]; then
                    echo -e "  - ${GREEN}Jours restants: $days_remaining${NC}"
                else
                    echo -e "  - ${RED}Certificat expiré ou invalide${NC}"
                fi
            else
                echo -e "\n${RED}Aucun certificat SSL trouvé${NC}"
            fi
        fi
    else
        if $JSON_OUTPUT; then
            output_json "$SERVER_NAME" "$INSTANCE_NAME" "$ssl_status" "$ssl_config" ""
        else
            echo -e "${YELLOW}✗ SSL n'est pas ACTIVÉ${NC}"
            echo -e "\n${YELLOW}Configuration SSL:${NC}"
            
            IFS=';' read -ra CONFIGS <<< "$ssl_config"
            for config in "${CONFIGS[@]}"; do
                if [[ -n "$config" ]]; then
                    IFS='|' read -r name setting unit context <<< "$config"
                    echo -e "  - $name: $setting $unit ($context)"
                fi
            done
        fi
    fi
    
    log "${GREEN}=== Analyse terminée ===${NC}"
}

# Gestion des erreurs
trap 'echo -e "${RED}Erreur lors de l'exécution du script${NC}"; exit 1' ERR

# Point d'entrée
main "$@"