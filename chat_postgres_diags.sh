#!/bin/bash

# Script d'analyse d'une instance PostgreSQL
# Doit être exécuté en tant que root ou avec sudo

set -e

# Fonction pour afficher un message d'erreur et quitter
error_exit() {
    echo "[ERREUR] $1" >&2
    exit 1
}

# Vérification que le script est exécuté en tant que root
if [ "$(id -u)" -ne 0 ]; then
    error_exit "Ce script doit être exécuté en tant que root (ou avec sudo)."
fi

# --- Étape 1 : Sélection de l'instance PostgreSQL ---
echo "=== Liste des processus postmaster en cours ==="
ps aux | grep postmaster | grep -v grep

# Demander à l'utilisateur de choisir un PID
read -p "Entrez le PID du processus postmaster à analyser : " POSTMASTER_PID

# Vérifier que le PID existe
if ! ps -p "$POSTMASTER_PID" > /dev/null; then
    error_exit "Le PID $POSTMASTER_PID n'existe pas ou n'est pas un processus postmaster."
fi

# Extraire le port et le data_directory depuis le processus postmaster
POSTGRES_PORT=$(ss -lptn | grep "$POSTMASTER_PID" | awk '{print $5}' | cut -d':' -f2)
POSTGRES_DATA_DIR=$(ps aux | grep "$POSTMASTER_PID" | grep -oP '--data-directory=\K[^ ]+')

if [ -z "$POSTGRES_PORT" ] || [ -z "$POSTGRES_DATA_DIR" ]; then
    error_exit "Impossible de déterminer le port ou le data_directory pour le PID $POSTMASTER_PID."
fi

echo "Instance PostgreSQL sélectionnée :"
echo "- PID : $POSTMASTER_PID"
echo "- Port : $POSTGRES_PORT"
echo "- Data Directory : $POSTGRES_DATA_DIR"

# --- Étape 2 : Vérifications système ---
echo -e "\n=== Vérifications système ==="

# Espace disque
echo -e "\n1. Espace disque sur le filesystem de $POSTGRES_DATA_DIR :"
df -h "$POSTGRES_DATA_DIR"

# CPU
echo -e "\n2. Utilisation CPU (moyenne sur 1 minute) :"
uptime

# Mémoire
echo -e "\n3. Utilisation mémoire :"
free -h

# --- Étape 3 : Vérifications PostgreSQL ---
echo -e "\n=== Vérifications PostgreSQL ==="

# Vérifier que les processus PostgreSQL sont opérationnels
echo -e "\n1. Processus PostgreSQL associés à l'instance :"
ps aux | grep "$POSTMASTER_PID" | grep -v grep

# --- Étape 4 : Analyse des logs (24 dernières heures) ---
echo -e "\n2. Erreurs dans les logs (24 dernières heures) :"
LOG_DIR="$POSTGRES_DATA_DIR/pg_log"
if [ -d "$LOG_DIR" ]; then
    find "$LOG_DIR" -type f -name "*.log" -exec grep -l "ERROR\|FATAL\|PANIC" {} + | xargs grep -A 2 -B 2 "ERROR\|FATAL\|PANIC" | tail -n 50
else
    echo "Aucun dossier de logs trouvé dans $LOG_DIR."
fi

# --- Étape 5 : Vérification des sessions ---
echo -e "\n3. Nombre de sessions actives vs. max_connections :"
sudo -u postgres psql -p "$POSTGRES_PORT" -c "
    SELECT
        (SELECT count(*) FROM pg_stat_activity) AS active_sessions,
        (SELECT setting FROM pg_settings WHERE name = 'max_connections') AS max_connections;
"

# --- Étape 6 : Requêtes longues ---
echo -e "\n4. Requêtes en cours depuis plus de 60 secondes :"
sudo -u postgres psql -p "$POSTGRES_PORT" -c "
    SELECT pid, now() - query_start AS duration, query, state
    FROM pg_stat_activity
    WHERE state = 'active' AND now() - query_start > interval '60 seconds'
    ORDER BY duration DESC;
"

# --- Étape 7 : Verrous bloquants ---
echo -e "\n5. Verrous bloquants :"
sudo -u postgres psql -p "$POSTGRES_PORT" -c "
    SELECT blocked_locks.pid AS blocked_pid,
           blocking_locks.pid AS blocking_pid,
           blocked_activity.query AS blocked_query,
           blocking_activity.query AS blocking_query
    FROM pg_catalog.pg_locks blocked_locks
    JOIN pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
    JOIN pg_catalog.pg_locks blocking_locks
        ON blocking_locks.locktype = blocked_locks.locktype
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
    JOIN pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
    WHERE NOT blocked_locks.GRANTED;
"

# --- Étape 8 : Deadlocks ---
echo -e "\n6. Deadlocks récents :"
sudo -u postgres psql -p "$POSTGRES_PORT" -c "
    SELECT * FROM pg_stat_database_conflicts;
"

