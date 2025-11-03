#!/bin/bash

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Répertoire des scripts SQL
SQL_SCRIPT_DIR="/tmp/mbu/sql"
LOG_DIR="/tmp/mbu/logs"
REBOUND_SERVER="votre_serveur_de_rebond"  # À adapter

# Fonction pour afficher le menu principal
display_main_menu() {
    clear
    echo -e "${YELLOW}===== MENU PRINCIPAL =====${NC}"
    echo "1. Administration"
    echo "2. Exploitation"
    echo "3. Performances"
    echo "4. Sauvegardes"
    echo "5. Restaurations"
    echo "6. Quitter"
    echo -n "Choisissez une option [1-6] : "
}

# Fonction pour choisir le fichier postgresql.conf
choose_postgresql_conf() {
    local conf_files=($(find / -name "postgresql.conf" 2>/dev/null))
    if [ ${#conf_files[@]} -eq 0 ]; then
        echo -e "${RED}Aucun fichier postgresql.conf trouvé.${NC}"
        exit 1
    fi
    echo -e "${YELLOW}===== Choix du fichier postgresql.conf =====${NC}"
    for i in "${!conf_files[@]}"; do
        echo "$((i+1)). ${conf_files[$i]}"
    done
    echo -n "Choisissez un fichier [1-${#conf_files[@]}] : "
    read choice
    local selected_conf="${conf_files[$((choice-1))]}"
    local port=$(grep -E "^port\s*=" "$selected_conf" | awk -F= '{print $2}' | tr -d ' ')
    echo "$port"
}

# Fonction pour afficher les infos du serveur
server_info() {
    local port=$1
    echo -e "${YELLOW}===== INFOS SERVEUR =====${NC}"
    echo -e "${GREEN}Nom du serveur :${NC} $(hostname)"
    echo -e "${GREEN}IP du serveur :${NC} $(hostname -I)"
    echo -e "${GREEN}Statut (master/slave) :${NC} À implémenter"
    echo -e "${GREEN}Dernier démarrage :${NC} $(who -b | awk '{print $3 " " $4}')"
    echo -e "${GREEN}Paramètres d'environnement :${NC}"
    env | grep -i postgres
    echo -e "${GREEN}Cluster :${NC} À implémenter"
    echo -e "${GREEN}État de la réplication :${NC} À implémenter"
    echo -e "${GREEN}État des archives :${NC} À implémenter"
    echo -e "${GREEN}FS avec plus de 80% d'occupation :${NC}"
    df -h | awk '$5 > 80 {print}'
    echo -e "${GREEN}Messages d'erreur système récents :${NC}"
    journalctl -xe --no-pager | tail -n 10
    echo -e "${GREEN}Derniers messages d'erreur PostgreSQL :${NC}"
    grep -i "error" /var/log/postgresql/postgresql-*.log | tail -n 10
    echo -e "${GREEN}Versions de PostgreSQL installées :${NC}"
    psql --version
    echo -e "${GREEN}Databases et leur taille :${NC}"
    psql -p "$port" -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database;"
    echo -e "${GREEN}FS utilisés pour l'instance PostgreSQL :${NC}"
    psql -p "$port" -c "SHOW data_directory;"
    echo -e "${GREEN}Configuration SSL :${NC}"
    psql -p "$port" -c "SHOW ssl;"
}

# Fonction pour exécuter un script SQL
execute_sql_script() {
    local port=$1
    local db_name=$2
    local script_path=$3
    local log_file="${LOG_DIR}/$(basename "$script_path" | sed 's/\.sql$/.log/')"
    echo -e "${YELLOW}Exécution du script $script_path sur $db_name...${NC}"
    psql -p "$port" -d "$db_name" -f "$script_path" > "$log_file" 2>&1
    chmod 777 "$log_file"
    echo -e "${GREEN}Log généré : $log_file${NC}"
    scp -p "$log_file" "${REBOUND_SERVER}:/chemin/vers/destination/" && echo -e "${GREEN}Log copié vers le serveur de rebond.${NC}" || echo -e "${RED}Échec de la copie.${NC}"
}

# Fonction pour extraire vers CSV
extract_to_csv() {
    local port=$1
    local db_name=$2
    local script_path=$3
    local csv_file="${LOG_DIR}/$(basename "$script_path" | sed 's/\.sql$/.csv/')"
    echo -e "${YELLOW}Extraction vers CSV depuis $script_path sur $db_name...${NC}"
    psql -p "$port" -d "$db_name" -c "\dt PASSING_TO_CSV" && psql -p "$port" -d "$db_name" -c "DROP TABLE PASSING_TO_CSV;"
    psql -p "$port" -d "$db_name" -c "CREATE TABLE PASSING_TO_CSV AS $(cat "$script_path");"
    psql -p "$port" -d "$db_name" -c "\COPY (SELECT * FROM PASSING_TO_CSV) TO '$csv_file' WITH (FORMAT csv, DELIMITER ';', ENCODING 'UTF8');"
    psql -p "$port" -d "$db_name" -c "DROP TABLE PASSING_TO_CSV;"
    echo -e "${GREEN}Fichier CSV généré : $csv_file${NC}"
}

# Fonction pour renommer une database
rename_database() {
    local port=$1
    local old_name=$2
    local new_name=$3
    echo -e "${YELLOW}Renommage de $old_name en $new_name...${NC}"
    # Vérifications préalables
    if psql -p "$port" -lqt | cut -d \| -f 1 | grep -qw "$old_name"; then
        if ! psql -p "$port" -lqt | cut -d \| -f 1 | grep -qw "$new_name"; then
            psql -p "$port" -c "ALTER DATABASE \"$old_name\" RENAME TO \"$new_name\";"
            echo -e "${GREEN}Database renommée avec succès.${NC}"
            psql -p "$port" -l
        else
            echo -e "${RED}La database $new_name existe déjà.${NC}"
        fi
    else
        echo -e "${RED}La database $old_name n'existe pas.${NC}"
    fi
}

# Fonction pour réaliser un dump
database_dump() {
    local port=$1
    local db_name=$2
    local dump_type=$3
    local compress=$4
    local dump_file="${LOG_DIR}/${db_name}_$(date +%Y%m%d).dump"
    if [ "$compress" = "oui" ]; then
        dump_file="${dump_file}.gz"
    fi
    echo -e "${YELLOW}Dump de $db_name en cours...${NC}"
    if [ "$dump_type" = "structure" ]; then
        pg_dump -p "$port" -s -Fc "$db_name" > "$dump_file"
    else
        pg_dump -p "$port" -Fc "$db_name" > "$dump_file"
    fi
    if [ "$compress" = "oui" ]; then
        gzip "$dump_file"
    fi
    echo -e "${GREEN}Dump terminé : $dump_file${NC}"
    scp -p "$dump_file" "${REBOUND_SERVER}:/chemin/vers/destination/" && echo -e "${GREEN}Dump copié vers le serveur de rebond.${NC}" || echo -e "${RED}Échec de la copie.${NC}"
}

# Fonction pour restaurer une database
restore_database() {
    local port=$1
    local db_name=$2
    local dump_file=$3
    echo -e "${YELLOW}Restauration de $db_name depuis $dump_file...${NC}"
    if [[ "$dump_file" == *.gz ]]; then
        gunzip -c "$dump_file" | pg_restore -p "$port" -d "$db_name" -Fc
    else
        pg_restore -p "$port" -d "$db_name" -Fc "$dump_file"
    fi
    echo -e "${GREEN}Restauration terminée.${NC}"
}

# Fonction pour afficher les paramètres de performance
performance_parameters() {
    local port=$1
    echo -e "${YELLOW}===== PARAMÈTRES DE PERFORMANCE =====${NC}"
    psql -p "$port" -c "SHOW all;" | grep -E "work_mem|shared_buffers|effective_cache_size|maintenance_work_mem|max_connections"
}

# Fonction pour afficher les requêtes les plus coûteuses
expensive_queries() {
    local port=$1
    echo -e "${YELLOW}===== REQUÊTES LES PLUS COÛTEUSES =====${NC}"
    psql -p "$port" -c "SELECT query, total_time, calls FROM pg_stat_statements ORDER BY total_time DESC LIMIT 10;"
}

# Menu Administration
administration_menu() {
    local port=$(choose_postgresql_conf)
    echo -e "${YELLOW}===== ADMINISTRATION =====${NC}"
    echo "1. Infos Serveur"
    echo "2. Retour"
    echo -n "Choisissez une option [1-2] : "
    read choice
    case $choice in
        1) server_info "$port" ;;
        2) return ;;
        *) echo -e "${RED}Option invalide.${NC}" ;;
    esac
}

# Menu Exploitation
exploitation_menu() {
    local port=$(choose_postgresql_conf)
    echo -e "${YELLOW}===== EXPLOITATION =====${NC}"
    echo "1. Exécuter un script SQL"
    echo "2. Extraction vers CSV"
    echo "3. Renommer une database"
    echo "4. Retour"
    echo -n "Choisissez une option [1-4] : "
    read choice
    case $choice in
        1)
            echo -e "${YELLOW}===== EXÉCUTION SCRIPT SQL =====${NC}"
            local scripts=($(ls "$SQL_SCRIPT_DIR"/*.sql 2>/dev/null))
            if [ ${#scripts[@]} -eq 0 ]; then
                echo -e "${RED}Aucun script SQL trouvé dans $SQL_SCRIPT_DIR.${NC}"
                return
            fi
            for i in "${!scripts[@]}"; do
                echo "$((i+1)). $(basename "${scripts[$i]}")"
            done
            echo -n "Choisissez un script [1-${#scripts[@]}] : "
            read script_choice
            local selected_script="${scripts[$((script_choice-1))]}"
            echo -e "${YELLOW}Choisissez la database :${NC}"
            psql -p "$port" -l
            echo -n "Nom de la database : "
            read db_name
            execute_sql_script "$port" "$db_name" "$selected_script"
            ;;
        2)
            echo -e "${YELLOW}===== EXTRACTION VERS CSV =====${NC}"
            local scripts=($(ls "$SQL_SCRIPT_DIR"/*.sql 2>/dev/null))
            if [ ${#scripts[@]} -eq 0 ]; then
                echo -e "${RED}Aucun script SQL trouvé dans $SQL_SCRIPT_DIR.${NC}"
                return
            fi
            for i in "${!scripts[@]}"; do
                echo "$((i+1)). $(basename "${scripts[$i]}")"
            done
            echo -n "Choisissez un script [1-${#scripts[@]}] : "
            read script_choice
            local selected_script="${scripts[$((script_choice-1))]}"
            echo -e "${YELLOW}Choisissez la database :${NC}"
            psql -p "$port" -l
            echo -n "Nom de la database : "
            read db_name
            extract_to_csv "$port" "$db_name" "$selected_script"
            ;;
        3)
            echo -e "${YELLOW}===== RENAME DATABASE =====${NC}"
            echo -e "${YELLOW}Choisissez la database à renommer :${NC}"
            psql -p "$port" -l
            echo -n "Nom de la database actuelle : "
            read old_name
            echo -n "Nouveau nom : "
            read new_name
            rename_database "$port" "$old_name" "$new_name"
            ;;
        4) return ;;
        *) echo -e "${RED}Option invalide.${NC}" ;;
    esac
}

# Menu Performances
performance_menu() {
    local port=$(choose_postgresql_conf)
    echo -e "${YELLOW}===== PERFORMANCES =====${NC}"
    echo "1. Paramètres de performance"
    echo "2. Requêtes les plus coûteuses"
    echo "3. Retour"
    echo -n "Choisissez une option [1-3] : "
    read choice
    case $choice in
        1) performance_parameters "$port" ;;
        2) expensive_queries "$port" ;;
        3) return ;;
        *) echo -e "${RED}Option invalide.${NC}" ;;
    esac
}

# Menu Sauvegardes
backup_menu() {
    local port=$(choose_postgresql_conf)
    echo -e "${YELLOW}===== SAUVEGARDES =====${NC}"
    echo "1. Dump d'une database"
    echo "2. Dump complet (pg_dumpall)"
    echo "3. Retour"
    echo -n "Choisissez une option [1-3] : "
    read choice
    case $choice in
        1)
            echo -e "${YELLOW}Choisissez la database :${NC}"
            psql -p "$port" -l
            echo -n "Nom de la database : "
            read db_name
            echo -e "${YELLOW}Type de dump (structure/complet) :${NC}"
            echo "1. Structure"
            echo "2. Complet"
            echo -n "Choisissez une option [1-2] : "
            read dump_type_choice
            local dump_type="complet"
            if [ "$dump_type_choice" = "1" ]; then
                dump_type="structure"
            fi
            echo -e "${YELLOW}Compresser le dump ? (oui/non) :${NC}"
            read compress
            database_dump "$port" "$db_name" "$dump_type" "$compress"
            ;;
        2)
            echo -e "${YELLOW}Dump complet (pg_dumpall)...${NC}"
            local dump_file="${LOG_DIR}/pg_dumpall_$(date +%Y%m%d).dump"
            pg_dumpall -p "$port" > "$dump_file"
            echo -e "${GREEN}Dump complet terminé : $dump_file${NC}"
            scp -p "$dump_file" "${REBOUND_SERVER}:/chemin/vers/destination/" && echo -e "${GREEN}Dump copié vers le serveur de rebond.${NC}" || echo -e "${RED}Échec de la copie.${NC}"
            ;;
        3) return ;;
        *) echo -e "${RED}Option invalide.${NC}" ;;
    esac
}

# Menu Restaurations
restore_menu() {
    local port=$(choose_postgresql_conf)
    echo -e "${YELLOW}===== RESTAURATIONS =====${NC}"
    echo "1. Restaurer une database"
    echo "2. Retour"
    echo -n "Choisissez une option [1-2] : "
    read choice
    case $choice in
        1)
            echo -e "${YELLOW}Choisissez la database :${NC}"
            psql -p "$port" -l
            echo -n "Nom de la database : "
            read db_name
            echo -e "${YELLOW}Choisissez le fichier de dump :${NC}"
            local dumps=($(ls "$LOG_DIR"/*.dump* 2>/dev/null))
            if [ ${#dumps[@]} -eq 0 ]; then
                echo -e "${RED}Aucun dump trouvé dans $LOG_DIR.${NC}"
                return
            fi
            for i in "${!dumps[@]}"; do
                echo "$((i+1)). $(basename "${dumps[$i]}")"
            done
            echo -n "Choisissez un dump [1-${#dumps[@]}] : "
            read dump_choice
            local selected_dump="${dumps[$((dump_choice-1))]}"
            restore_database "$port" "$db_name" "$selected_dump"
            ;;
        2) return ;;
        *) echo -e "${RED}Option invalide.${NC}" ;;
    esac
}

# Boucle principale
while true; do
    display_main_menu
    read main_choice
    case $main_choice in
        1) administration_menu ;;
        2) exploitation_menu ;;
        3) performance_menu ;;
        4) backup_menu ;;
        5) restore_menu ;;
        6) echo -e "${GREEN}Au revoir !${NC}"; exit 0 ;;
        *) echo -e "${RED}Option invalide.${NC}" ;;
    esac
    echo -n "Appuyez sur Entrée pour continuer..."
    read
done

