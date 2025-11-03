#!/bin/bash

# Script d'analyse PostgreSQL - Diagnostic complet
# Auteur: Assistant IA
# Usage: ./postgres_diagnostic.sh

set -e

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Fonctions d'affichage
print_header() {
    echo -e "${BLUE}"
    echo "=========================================="
    echo "   DIAGNOSTIC POSTGRESQL"
    echo "=========================================="
    echo -e "${NC}"
}

print_section() {
    echo -e "${YELLOW}"
    echo "--- $1 ---"
    echo -e "${NC}"
}

print_success() {
    echo -e "${GREEN}[SUCCÈS] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[ATTENTION] $1${NC}"
}

print_error() {
    echo -e "${RED}[ERREUR] $1${NC}"
}

# Vérification des privilèges
check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        print_warning "Exécution en tant que root - basculement vers postgres recommandé"
    fi
}

# Sélection de l'instance Postgres
select_postgres_instance() {
    print_section "SÉLECTION DE L'INSTANCE POSTGRESQL"
    
    # Recherche des processus postmaster
    echo "Processus postmaster trouvés :"
    echo "--------------------------------"
    
    pg_processes=$(ps aux | grep postmaster | grep -v grep || true)
    
    if [[ -z "$pg_processes" ]]; then
        print_error "Aucun processus postmaster trouvé"
        exit 1
    fi
    
    # Affichage des processus avec numérotation
    IFS=$'\n'
    count=1
    declare -a process_map
    
    for process in $pg_processes; do
        echo "$count: $process"
        process_map[$count]=$process
        ((count++))
    done
    unset IFS
    
    echo "--------------------------------"
    read -p "Sélectionnez le numéro de l'instance à analyser [1]: " choice
    
    # Valeur par défaut
    choice=${choice:-1}
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -ge $count ]]; then
        print_error "Sélection invalide"
        exit 1
    fi
    
    selected_process="${process_map[$choice]}"
    
    # Extraction du port et du répertoire de données
    port=$(echo "$selected_process" | grep -oP 'port=\K[0-9]+' || echo "5432")
    data_dir=$(echo "$selected_process" | grep -oP 'D\s+\K[^ ]+' || echo "")
    
    print_success "Instance sélectionnée - Port: $port, Data: $data_dir"
    
    export PGPORT=$port
}

# Vérification des ressources système
check_system_resources() {
    print_section "VÉRIFICATION DES RESSOURCES SYSTÈME"
    
    # Espace disque
    echo "Espace disque disponible :"
    df -h | grep -E "(Filesystem|/dev)" | head -10
    
    # Vérification spécifique pour PostgreSQL
    if [[ -n "$data_dir" ]] && [[ -d "$data_dir" ]]; then
        echo ""
        echo "Espace pour le répertoire de données PostgreSQL ($data_dir):"
        df -h "$data_dir"
    fi
    
    # Mémoire
    echo ""
    echo "Utilisation mémoire :"
    free -h
    
    # CPU - charge système
    echo ""
    echo "Charge CPU (load average) :"
    uptime
    
    # Vérification des processus PostgreSQL
    echo ""
    echo "Processus PostgreSQL en cours :"
    pg_count=$(ps aux | grep postgres | grep -v grep | wc -l)
    echo "Nombre de processus PostgreSQL: $pg_count"
    
    if [[ $pg_count -eq 0 ]]; then
        print_error "Aucun processus PostgreSQL trouvé !"
        exit 1
    fi
}

# Analyse PostgreSQL (nécessite les droits postgres)
analyze_postgres() {
    print_section "ANALYSE POSTGRESQL"
    
    # Vérification de la connexion
    if ! command -v psql &> /dev/null; then
        print_error "psql non trouvé - installation PostgreSQL requise"
        return 1
    fi
    
    # Test de connexion basique
    if ! psql -c "SELECT version();" postgres > /dev/null 2>&1; then
        print_warning "Connexion PostgreSQL échouée - tentative avec sudo"
        
        # Essai avec sudo
        if ! sudo -u postgres psql -c "SELECT version();" postgres > /dev/null 2>&1; then
            print_error "Impossible de se connecter à PostgreSQL"
            return 1
        else
            PG_CMD="sudo -u postgres psql"
        fi
    else
        PG_CMD="psql"
    fi
    
    print_success "Connexion PostgreSQL établie"
    
    # Sessions actives
    echo ""
    echo "Sessions actives et paramètre max_connections :"
    $PG_CMD -c "
    SELECT 
        setting AS max_connections,
        (SELECT count(*) FROM pg_stat_activity) AS current_connections,
        setting::int - (SELECT count(*) FROM pg_stat_activity) AS remaining_connections
    FROM pg_settings 
    WHERE name = 'max_connections';
    " postgres
    
    # Sessions par état
    echo ""
    echo "Sessions par état :"
    $PG_CMD -c "
    SELECT state, count(*) 
    FROM pg_stat_activity 
    WHERE datname IS NOT NULL 
    GROUP BY state 
    ORDER BY count DESC;
    " postgres
    
    # Requêtes longues
    echo ""
    echo "Requêtes en cours depuis plus de 5 minutes :"
    $PG_CMD -c "
    SELECT 
        pid,
        now() - pg_stat_activity.query_start AS duration,
        datname,
        usename,
        state,
        query
    FROM pg_stat_activity 
    WHERE (now() - pg_stat_activity.query_start) > interval '5 minutes'
    AND state = 'active';
    " postgres
    
    # Verrous bloquants
    echo ""
    echo "Verrous bloquants :"
    $PG_CMD -c "
    SELECT 
        blocked_locks.pid AS blocked_pid,
        blocked_activity.usename AS blocked_user,
        blocking_locks.pid AS blocking_pid,
        blocking_activity.usename AS blocking_user,
        blocked_activity.query AS blocked_statement,
        blocking_activity.query AS current_statement_in_blocking_process
    FROM pg_catalog.pg_locks blocked_locks
    JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
    JOIN pg_catalog.pg_locks blocking_locks ON blocking_locks.locktype = blocked_locks.locktype
        AND blocking_locks.DATABASE IS NOT DISTINCT FROM blocked_locks.DATABASE
        AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
        AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
        AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
        AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
        AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
        AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
        AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
        AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
        AND blocking_locks.pid != blocked_locks.pid
    JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
    WHERE NOT blocked_locks.GRANTED;
    " postgres
    
    # Deadlocks dans les logs (nécessite l'accès aux logs)
    echo ""
    echo "Statistiques des bases de données :"
    $PG_CMD -c "
    SELECT 
        datname,
        numbackends as connections,
        xact_commit as commits,
        xact_rollback as rollbacks,
        blks_read as blocks_read,
        blks_hit as blocks_hit
    FROM pg_stat_database 
    WHERE datname IS NOT NULL;
    " postgres
}

# Analyse des logs PostgreSQL
analyze_logs() {
    print_section "ANALYSE DES LOGS POSTGRESQL"
    
    # Recherche du répertoire de logs
    log_dirs=(
        "/var/lib/pgsql/*/data/pg_log"
        "/var/lib/pgsql/*/log"
        "/var/log/postgresql"
        "/usr/local/var/postgres"
        "$data_dir/pg_log"
        "$data_dir/log"
    )
    
    log_dir=""
    for dir in "${log_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            log_dir="$dir"
            break
        fi
    done
    
    if [[ -z "$log_dir" ]]; then
        print_warning "Répertoire de logs non trouvé automatiquement"
        echo "Veuillez spécifier le chemin du répertoire de logs: "
        read -p "Chemin: " log_dir
    fi
    
    if [[ -d "$log_dir" ]]; then
        print_success "Répertoire de logs trouvé: $log_dir"
        
        # Recherche des erreurs dans les dernières 24h
        echo ""
        echo "Erreurs dans les logs des dernières 24h :"
        
        find "$log_dir" -name "*.log" -type f -mtime -1 -exec grep -l -i "error\|fatal\|panic" {} \; | while read logfile; do
            echo "Fichier: $logfile"
            grep -i "error\|fatal\|panic" "$logfile" | tail -20
        done
        
        # Comptage des erreurs par type
        echo ""
        echo "Statistiques des erreurs (24h) :"
        find "$log_dir" -name "*.log" -type f -mtime -1 -exec cat {} \; | \
            grep -i "error\|fatal\|panic" | \
            sed 's/.*ERROR: *//I; s/.*FATAL: *//I; s/.*PANIC: *//I' | \
            cut -d' ' -f1-5 | \
            sort | uniq -c | sort -rn | head -10
            
    else
        print_warning "Répertoire de logs inaccessible: $log_dir"
    fi
}

# Résumé et recommandations
generate_summary() {
    print_section "RÉSUMÉ ET RECOMMANDATIONS"
    
    echo "Vérifications effectuées :"
    echo "✓ Ressources système (CPU, mémoire, disque)"
    echo "✓ Processus PostgreSQL"
    echo "✓ Sessions et connexions"
    echo "✓ Requêtes longues"
    echo "✓ Verrous bloquants"
    echo "✓ Analyse des logs"
    echo ""
    echo "Prochaines étapes recommandées :"
    echo "1. Vérifier les erreurs spécifiques dans les logs"
    echo "2. Analyser les requêtes longues identifiées"
    echo "3. Surveiller l'utilisation des connexions"
    echo "4. Vérifier la configuration PostgreSQL (postgresql.conf)"
    echo "5. Contrôler la maintenance (VACUUM, ANALYZE)"
}

# Fonction principale
main() {
    print_header
    check_privileges
    select_postgres_instance
    check_system_resources
    analyze_postgres
    analyze_logs
    generate_summary
}

# Gestion des erreurs
trap 'print_error "Script interrompu"; exit 1' INT TERM

# Point d'entrée
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi