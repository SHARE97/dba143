#!/bin/bash

################################################################################
# Script d'Administration PostgreSQL
# Doit être exécuté avec le compte postgres
################################################################################

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Répertoires
SQL_DIR="/tmp/mbu/sql"
LOG_DIR="/tmp/mbu/logs"
BACKUP_DIR="/tmp/mbu/backups"
CSV_DIR="/tmp/mbu/csv"

# Serveur de rebond (à configurer)
REBOUND_SERVER="user@serveur-rebond"
REBOUND_PATH="/remote/path/"

# Variables globales
SELECTED_CONF=""
SELECTED_PORT=""
SELECTED_DB=""

################################################################################
# Fonctions utilitaires
################################################################################

create_directories() {
    mkdir -p "$SQL_DIR" "$LOG_DIR" "$BACKUP_DIR" "$CSV_DIR"
}

print_header() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       OUTIL D'ADMINISTRATION POSTGRESQL                    ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERREUR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[ATTENTION]${NC} $1"
}

pause() {
    echo ""
    read -p "Appuyez sur ENTRÉE pour continuer..."
}

################################################################################
# Configuration PostgreSQL
################################################################################

find_postgresql_configs() {
    print_info "Recherche des fichiers postgresql.conf..."
    mapfile -t CONFIGS < <(find /etc /var /opt -name "postgresql.conf" 2>/dev/null)
    
    if [ ${#CONFIGS[@]} -eq 0 ]; then
        print_error "Aucun fichier postgresql.conf trouvé"
        return 1
    fi
    
    return 0
}

select_postgresql_config() {
    find_postgresql_configs || return 1
    
    echo ""
    echo "Fichiers postgresql.conf disponibles :"
    echo ""
    for i in "${!CONFIGS[@]}"; do
        echo "$((i+1))) ${CONFIGS[$i]}"
    done
    echo ""
    
    read -p "Sélectionnez le fichier de configuration (1-${#CONFIGS[@]}) : " choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#CONFIGS[@]} ]; then
        print_error "Choix invalide"
        return 1
    fi
    
    SELECTED_CONF="${CONFIGS[$((choice-1))]}"
    SELECTED_PORT=$(grep "^port" "$SELECTED_CONF" | sed "s/.*=[[:space:]]*\([0-9]*\).*/\1/" | head -1)
    
    if [ -z "$SELECTED_PORT" ]; then
        SELECTED_PORT="5432"
        print_warning "Port non trouvé dans la config, utilisation du port par défaut : 5432"
    fi
    
    print_info "Configuration sélectionnée : $SELECTED_CONF"
    print_info "Port PostgreSQL : $SELECTED_PORT"
    
    return 0
}

list_databases() {
    psql -p "$SELECTED_PORT" -U postgres -lt | grep -v "template" | awk -F '|' '{print $1}' | grep -v "^$" | grep -v "Name" | sed 's/^[[:space:]]*//'
}

select_database() {
    echo ""
    echo "Bases de données disponibles :"
    echo ""
    
    mapfile -t DBS < <(list_databases)
    
    for i in "${!DBS[@]}"; do
        echo "$((i+1))) ${DBS[$i]}"
    done
    echo ""
    
    read -p "Sélectionnez la base de données (1-${#DBS[@]}) : " choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#DBS[@]} ]; then
        print_error "Choix invalide"
        return 1
    fi
    
    SELECTED_DB="${DBS[$((choice-1))]}"
    print_info "Base de données sélectionnée : $SELECTED_DB"
    
    return 0
}

################################################################################
# EXPLOITATION - Exécution SQL
################################################################################

execute_sql_script() {
    print_header
    echo "=== EXÉCUTION DE SCRIPTS SQL ==="
    echo ""
    
    select_postgresql_config || { pause; return; }
    select_database || { pause; return; }
    
    echo ""
    echo "Scripts SQL disponibles dans $SQL_DIR :"
    echo ""
    
    if [ ! -d "$SQL_DIR" ] || [ -z "$(ls -A $SQL_DIR/*.sql 2>/dev/null)" ]; then
        print_error "Aucun script SQL trouvé dans $SQL_DIR"
        pause
        return
    fi
    
    mapfile -t SCRIPTS < <(ls -1 "$SQL_DIR"/*.sql 2>/dev/null)
    
    for i in "${!SCRIPTS[@]}"; do
        echo "$((i+1))) $(basename ${SCRIPTS[$i]})"
    done
    echo ""
    
    read -p "Sélectionnez le script à exécuter (1-${#SCRIPTS[@]}) : " choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#SCRIPTS[@]} ]; then
        print_error "Choix invalide"
        pause
        return
    fi
    
    SCRIPT_FILE="${SCRIPTS[$((choice-1))]}"
    SCRIPT_NAME=$(basename "$SCRIPT_FILE" .sql)
    LOG_FILE="$LOG_DIR/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S).log"
    
    print_info "Exécution du script : $SCRIPT_FILE"
    print_info "Fichier de log : $LOG_FILE"
    echo ""
    
    # Exécution du script avec log
    {
        echo "=== Exécution du script SQL ==="
        echo "Date : $(date)"
        echo "Script : $SCRIPT_FILE"
        echo "Database : $SELECTED_DB"
        echo "Port : $SELECTED_PORT"
        echo "================================"
        echo ""
        
        psql -p "$SELECTED_PORT" -U postgres -d "$SELECTED_DB" -f "$SCRIPT_FILE" 2>&1
        
        echo ""
        echo "================================"
        echo "Fin d'exécution : $(date)"
    } | tee "$LOG_FILE"
    
    chmod 777 "$LOG_FILE"
    
    if [ $? -eq 0 ]; then
        print_info "Script exécuté avec succès"
    else
        print_error "Erreur lors de l'exécution du script"
    fi
    
    # Copie vers serveur de rebond
    read -p "Envoyer le log vers le serveur de rebond ? (o/N) : " send_log
    if [[ "$send_log" =~ ^[oO]$ ]]; then
        scp -p "$LOG_FILE" "$REBOUND_SERVER:$REBOUND_PATH" && print_info "Log envoyé avec succès" || print_error "Erreur lors de l'envoi du log"
    fi
    
    pause
}

################################################################################
# EXPLOITATION - Extraction CSV
################################################################################

extract_to_csv() {
    print_header
    echo "=== EXTRACTION VERS CSV ==="
    echo ""
    
    select_postgresql_config || { pause; return; }
    select_database || { pause; return; }
    
    echo ""
    echo "Scripts SQL disponibles pour extraction :"
    echo ""
    
    if [ ! -d "$SQL_DIR" ] || [ -z "$(ls -A $SQL_DIR/*.sql 2>/dev/null)" ]; then
        print_error "Aucun script SQL trouvé dans $SQL_DIR"
        pause
        return
    fi
    
    mapfile -t SCRIPTS < <(ls -1 "$SQL_DIR"/*.sql 2>/dev/null)
    
    for i in "${!SCRIPTS[@]}"; do
        echo "$((i+1))) $(basename ${SCRIPTS[$i]})"
    done
    echo ""
    
    read -p "Sélectionnez le script SELECT pour l'extraction (1-${#SCRIPTS[@]}) : " choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#SCRIPTS[@]} ]; then
        print_error "Choix invalide"
        pause
        return
    fi
    
    SCRIPT_FILE="${SCRIPTS[$((choice-1))]}"
    SCRIPT_NAME=$(basename "$SCRIPT_FILE" .sql)
    CSV_FILE="$CSV_DIR/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S).csv"
    
    print_info "Extraction depuis : $SCRIPT_FILE"
    print_info "Fichier CSV : $CSV_FILE"
    echo ""
    
    # Création de la table intermédiaire
    print_info "Étape 1/4 : Création de la table PASSING_TO_CSV..."
    QUERY=$(cat "$SCRIPT_FILE")
    
    psql -p "$SELECTED_PORT" -U postgres -d "$SELECTED_DB" <<EOF
DROP TABLE IF EXISTS PASSING_TO_CSV;
CREATE TABLE PASSING_TO_CSV AS $QUERY;
EOF
    
    if [ $? -ne 0 ]; then
        print_error "Erreur lors de la création de la table intermédiaire"
        pause
        return
    fi
    
    print_info "Étape 2/4 : Comptage des enregistrements..."
    ROW_COUNT=$(psql -p "$SELECTED_PORT" -U postgres -d "$SELECTED_DB" -t -c "SELECT COUNT(*) FROM PASSING_TO_CSV;")
    print_info "Nombre d'enregistrements : $(echo $ROW_COUNT | xargs)"
    
    # Extraction CSV
    print_info "Étape 3/4 : Export vers CSV..."
    psql -p "$SELECTED_PORT" -U postgres -d "$SELECTED_DB" <<EOF
\COPY PASSING_TO_CSV TO '$CSV_FILE' WITH (FORMAT CSV, DELIMITER ';', ENCODING 'UTF8', HEADER);
EOF
    
    if [ $? -ne 0 ]; then
        print_error "Erreur lors de l'extraction CSV"
        psql -p "$SELECTED_PORT" -U postgres -d "$SELECTED_DB" -c "DROP TABLE IF EXISTS PASSING_TO_CSV;"
        pause
        return
    fi
    
    # Nettoyage
    print_info "Étape 4/4 : Suppression de la table intermédiaire..."
    psql -p "$SELECTED_PORT" -U postgres -d "$SELECTED_DB" -c "DROP TABLE PASSING_TO_CSV;"
    
    chmod 644 "$CSV_FILE"
    
    print_info "Extraction réussie : $CSV_FILE"
    print_info "Taille du fichier : $(du -h $CSV_FILE | cut -f1)"
    
    # Copie vers serveur de rebond
    read -p "Envoyer le CSV vers le serveur de rebond ? (o/N) : " send_csv
    if [[ "$send_csv" =~ ^[oO]$ ]]; then
        scp -p "$CSV_FILE" "$REBOUND_SERVER:$REBOUND_PATH" && print_info "CSV envoyé avec succès" || print_error "Erreur lors de l'envoi du CSV"
    fi
    
    pause
}

################################################################################
# EXPLOITATION - Rename Database
################################################################################

rename_database() {
    print_header
    echo "=== RENOMMER UNE BASE DE DONNÉES ==="
    echo ""
    
    select_postgresql_config || { pause; return; }
    select_database || { pause; return; }
    
    OLD_NAME="$SELECTED_DB"
    
    echo ""
    read -p "Nouveau nom pour la base '$OLD_NAME' : " NEW_NAME
    
    if [ -z "$NEW_NAME" ]; then
        print_error "Le nouveau nom ne peut pas être vide"
        pause
        return
    fi
    
    # Vérifications
    print_info "Vérifications préalables..."
    
    # Vérifier si le nouveau nom existe déjà
    if psql -p "$SELECTED_PORT" -U postgres -lqt | cut -d \| -f 1 | grep -qw "$NEW_NAME"; then
        print_error "Une base de données nommée '$NEW_NAME' existe déjà"
        pause
        return
    fi
    
    # Compter les connexions actives
    ACTIVE_CONN=$(psql -p "$SELECTED_PORT" -U postgres -t -c "SELECT COUNT(*) FROM pg_stat_activity WHERE datname='$OLD_NAME' AND pid <> pg_backend_pid();")
    ACTIVE_CONN=$(echo $ACTIVE_CONN | xargs)
    
    print_info "Connexions actives sur '$OLD_NAME' : $ACTIVE_CONN"
    
    if [ "$ACTIVE_CONN" -gt 0 ]; then
        read -p "Forcer la déconnexion des utilisateurs ? (o/N) : " force_disconnect
        if [[ "$force_disconnect" =~ ^[oO]$ ]]; then
            print_warning "Fermeture des connexions actives..."
            psql -p "$SELECTED_PORT" -U postgres <<EOF
SELECT pg_terminate_backend(pid) 
FROM pg_stat_activity 
WHERE datname = '$OLD_NAME' AND pid <> pg_backend_pid();
EOF
        else
            print_error "Impossible de renommer avec des connexions actives"
            pause
            return
        fi
    fi
    
    # Renommage
    print_info "Renommage de '$OLD_NAME' en '$NEW_NAME'..."
    psql -p "$SELECTED_PORT" -U postgres <<EOF
ALTER DATABASE "$OLD_NAME" RENAME TO "$NEW_NAME";
EOF
    
    if [ $? -eq 0 ]; then
        print_info "Base de données renommée avec succès"
        echo ""
        print_info "Liste des bases de données actuelles :"
        list_databases
    else
        print_error "Erreur lors du renommage"
    fi
    
    pause
}

################################################################################
# SAUVEGARDES - Dump Database
################################################################################

dump_database() {
    print_header
    echo "=== SAUVEGARDE BASE DE DONNÉES ==="
    echo ""
    
    select_postgresql_config || { pause; return; }
    
    echo ""
    echo "Type de sauvegarde :"
    echo "1) Une base de données spécifique"
    echo "2) Toutes les bases (pg_dumpall)"
    echo "3) Toutes les bases (dumps séparés)"
    echo ""
    read -p "Votre choix (1-3) : " backup_type
    
    echo ""
    echo "Options de sauvegarde :"
    read -p "Compression ? (o/N) : " compress
    read -p "Structure uniquement (schema-only) ? (o/N) : " schema_only
    
    COMPRESS_OPT=""
    SCHEMA_OPT=""
    EXT=".sql"
    
    if [[ "$compress" =~ ^[oO]$ ]]; then
        COMPRESS_OPT="-Fc"
        EXT=".dump"
    fi
    
    if [[ "$schema_only" =~ ^[oO]$ ]]; then
        SCHEMA_OPT="--schema-only"
    fi
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    
    case $backup_type in
        1)
            select_database || { pause; return; }
            BACKUP_FILE="$BACKUP_DIR/${SELECTED_DB}_${TIMESTAMP}${EXT}"
            
            print_info "Sauvegarde de la base '$SELECTED_DB'..."
            pg_dump -p "$SELECTED_PORT" -U postgres $COMPRESS_OPT $SCHEMA_OPT "$SELECTED_DB" > "$BACKUP_FILE"
            
            if [ $? -eq 0 ]; then
                print_info "Sauvegarde réussie : $BACKUP_FILE"
                print_info "Taille : $(du -h $BACKUP_FILE | cut -f1)"
            else
                print_error "Erreur lors de la sauvegarde"
            fi
            ;;
            
        2)
            BACKUP_FILE="$BACKUP_DIR/pg_dumpall_${TIMESTAMP}.sql"
            
            print_info "Sauvegarde complète (pg_dumpall)..."
            pg_dumpall -p "$SELECTED_PORT" -U postgres $SCHEMA_OPT > "$BACKUP_FILE"
            
            if [ $? -eq 0 ]; then
                print_info "Sauvegarde réussie : $BACKUP_FILE"
                print_info "Taille : $(du -h $BACKUP_FILE | cut -f1)"
            else
                print_error "Erreur lors de la sauvegarde"
            fi
            ;;
            
        3)
            print_info "Sauvegarde de toutes les bases séparément..."
            mapfile -t ALL_DBS < <(list_databases)
            
            for db in "${ALL_DBS[@]}"; do
                BACKUP_FILE="$BACKUP_DIR/${db}_${TIMESTAMP}${EXT}"
                print_info "Sauvegarde de '$db'..."
                pg_dump -p "$SELECTED_PORT" -U postgres $COMPRESS_OPT $SCHEMA_OPT "$db" > "$BACKUP_FILE"
                
                if [ $? -eq 0 ]; then
                    print_info "  -> $(du -h $BACKUP_FILE | cut -f1)"
                else
                    print_error "  -> Erreur"
                fi
            done
            ;;
            
        *)
            print_error "Choix invalide"
            pause
            return
            ;;
    esac
    
    # Copie vers serveur de rebond
    echo ""
    read -p "Envoyer la sauvegarde vers le serveur de rebond ? (o/N) : " send_backup
    if [[ "$send_backup" =~ ^[oO]$ ]]; then
        if [ "$backup_type" -eq 3 ]; then
            scp -p "$BACKUP_DIR"/*_${TIMESTAMP}${EXT} "$REBOUND_SERVER:$REBOUND_PATH" && print_info "Sauvegardes envoyées" || print_error "Erreur lors de l'envoi"
        else
            scp -p "$BACKUP_FILE" "$REBOUND_SERVER:$REBOUND_PATH" && print_info "Sauvegarde envoyée" || print_error "Erreur lors de l'envoi"
        fi
    fi
    
    pause
}

################################################################################
# ADMINISTRATION - Informations Serveur
################################################################################

server_info() {
    print_header
    echo "=== INFORMATIONS SERVEUR ==="
    echo ""
    
    select_postgresql_config || { pause; return; }
    
    # Identité
    echo -e "${BLUE}=== IDENTITÉ ===${NC}"
    echo "Nom du serveur : $(hostname)"
    echo "Adresse IP : $(hostname -I | awk '{print $1}')"
    echo ""
    
    # Status PostgreSQL
    echo -e "${BLUE}=== POSTGRESQL ===${NC}"
    PG_VERSION=$(psql -p "$SELECTED_PORT" -U postgres -t -c "SELECT version();" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "Version : $(echo $PG_VERSION | xargs)"
        echo "Port : $SELECTED_PORT"
        echo "Fichier config : $SELECTED_CONF"
        
        # Uptime
        START_TIME=$(psql -p "$SELECTED_PORT" -U postgres -t -c "SELECT pg_postmaster_start_time();" 2>/dev/null)
        echo "Démarrage : $(echo $START_TIME | xargs)"
        
        # Master/Slave
        IS_REPLICA=$(psql -p "$SELECTED_PORT" -U postgres -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | xargs)
        if [ "$IS_REPLICA" = "t" ]; then
            echo -e "Status : ${YELLOW}SLAVE${NC}"
        else
            echo -e "Status : ${GREEN}MASTER${NC}"
        fi
    else
        print_error "PostgreSQL ne répond pas sur le port $SELECTED_PORT"
    fi
    
    echo ""
    
    # Bases de données et tailles
    echo -e "${BLUE}=== BASES DE DONNÉES ===${NC}"
    psql -p "$SELECTED_PORT" -U postgres -c "SELECT datname AS \"Base\", pg_size_pretty(pg_database_size(datname)) AS \"Taille\" FROM pg_database WHERE datistemplate = false ORDER BY pg_database_size(datname) DESC;"
    
    echo ""
    
    # Filesystems
    echo -e "${BLUE}=== SYSTÈMES DE FICHIERS (>80%) ===${NC}"
    df -h | head -1
    df -h | awk '$5+0 > 80 {print}'
    
    echo ""
    
    # SSL
    echo -e "${BLUE}=== SÉCURITÉ SSL ===${NC}"
    SSL_STATUS=$(psql -p "$SELECTED_PORT" -U postgres -t -c "SHOW ssl;" 2>/dev/null | xargs)
    if [ "$SSL_STATUS" = "on" ]; then
        echo -e "SSL : ${GREEN}ACTIVÉ${NC}"
        psql -p "$SELECTED_PORT" -U postgres -c "SELECT name, setting FROM pg_settings WHERE name LIKE 'ssl%';"
    else
        echo -e "SSL : ${YELLOW}DÉSACTIVÉ${NC}"
    fi
    
    pause
}

################################################################################
# PERFORMANCES - Paramètres
################################################################################

performance_params() {
    print_header
    echo "=== PARAMÈTRES DE PERFORMANCE ==="
    echo ""
    
    select_postgresql_config || { pause; return; }
    
    psql -p "$SELECTED_PORT" -U postgres <<EOF
SELECT name, setting, unit, short_desc 
FROM pg_settings 
WHERE category LIKE '%Resource%' OR category LIKE '%Query%' OR category LIKE '%WAL%'
ORDER BY category, name;
EOF
    
    pause
}

################################################################################
# PERFORMANCES - Requêtes coûteuses
################################################################################

slow_queries() {
    print_header
    echo "=== REQUÊTES LES PLUS COÛTEUSES ==="
    echo ""
    
    select_postgresql_config || { pause; return; }
    
    # Vérifier si pg_stat_statements est disponible
    HAS_STAT=$(psql -p "$SELECTED_PORT" -U postgres -t -c "SELECT COUNT(*) FROM pg_extension WHERE extname='pg_stat_statements';" 2>/dev/null | xargs)
    
    if [ "$HAS_STAT" -eq 0 ]; then
        print_warning "Extension pg_stat_statements non installée"
        echo ""
        echo "Requêtes actuellement en cours :"
        psql -p "$SELECTED_PORT" -U postgres <<EOF
SELECT pid, usename, datname, state, 
       now() - query_start AS duration,
       substring(query, 1, 60) AS query
FROM pg_stat_activity 
WHERE state != 'idle' 
  AND query NOT LIKE '%pg_stat_activity%'
ORDER BY duration DESC
LIMIT 20;
EOF
    else
        print_info "Top 20 des requêtes les plus coûteuses (pg_stat_statements)"
        psql -p "$SELECTED_PORT" -U postgres <<EOF
SELECT calls, 
       total_exec_time::numeric(10,2) AS total_time_ms,
       mean_exec_time::numeric(10,2) AS mean_time_ms,
       substring(query, 1, 80) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
EOF
    fi
    
    pause
}

################################################################################
# Menu Principal
################################################################################

show_menu() {
    print_header
    
    echo -e "${GREEN}ADMINISTRATION${NC}"
    echo "  1) Informations serveur"
    echo "  2) Informations bases de données"
    echo ""
    
    echo -e "${GREEN}EXPLOITATION${NC}"
    echo "  3) Exécution de scripts SQL"
    echo "  4) Extraction vers CSV"
    echo "  5) Renommer une base de données"
    echo ""
    
    echo -e "${GREEN}PERFORMANCES${NC}"
    echo "  6) Paramètres de performance"
    echo "  7) Requêtes les plus coûteuses"
    echo ""
    
    echo -e "${GREEN}SAUVEGARDES${NC}"
    echo "  8) Dump de base de données"
    echo ""
    
    echo -e "${GREEN}RESTAURATIONS${NC}"
    echo "  9) Restauration (À implémenter)"
    echo ""
    
    echo "  0) Quitter"
    echo ""
}

################################################################################
# Main
################################################################################

main() {
    # Vérifier que le script est exécuté par postgres
    if [ "$(whoami)" != "postgres" ]; then
        print_error "Ce script doit être exécuté avec le compte postgres"
        exit 1
    fi
    
    create_directories
    
    while true; do
        show_menu
        read -p "Votre choix : " choice
        
        case $choice in
            1) server_info ;;
            2) print_header; echo "À implémenter"; pause ;;
            3) execute_sql_script ;;
            4) extract_to_csv ;;
            5) rename_database ;;
            6) performance_params ;;
            7) slow_queries ;;
            8) dump_database ;;
            9) print_header; echo "Module de restauration à implémenter"; pause ;;
            0) print_info "Au revoir !"; exit 0 ;;
            *) print_error "Choix invalide"; pause ;;
        esac
    done
}

# Lancement du script
main