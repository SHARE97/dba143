#!/bin/bash

# Configuration
PG_HOST="localhost"
PG_PORT="5432"
PG_USER="postgres"
PG_DATA_DIR="/var/lib/postgresql/14/main"  # À adapter selon votre version et installation
BACKUP_DIR="/backups/postgres"
WAL_ARCHIVE_DIR="/backups/postgres/wal_archive"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="base_backup_$DATE"
LOG_FILE="$BACKUP_DIR/backup_$DATE.log"

# Vérification des paramètres PostgreSQL
check_pg_parameters() {
    echo "Vérification des paramètres PostgreSQL..." | tee -a $LOG_FILE

    # Vérifier wal_level
    wal_level=$(psql -h $PG_HOST -p $PG_PORT -U $PG_USER -t -c "SHOW wal_level;")
    if [ "$wal_level" != "replica" ]; then
        echo "ERREUR : wal_level doit être 'replica' ou 'logical' pour le PITR." | tee -a $LOG_FILE
        exit 1
    fi

    # Vérifier archive_mode
    archive_mode=$(psql -h $PG_HOST -p $PG_PORT -U $PG_USER -t -c "SHOW archive_mode;")
    if [ "$archive_mode" != "on" ]; then
        echo "ERREUR : archive_mode doit être 'on' pour le PITR." | tee -a $LOG_FILE
        exit 1
    fi

    # Vérifier archive_command
    archive_command=$(psql -h $PG_HOST -p $PG_PORT -U $PG_USER -t -c "SHOW archive_command;")
    if [ -z "$archive_command" ]; then
        echo "ERREUR : archive_command doit être configuré pour archiver les WAL." | tee -a $LOG_FILE
        exit 1
    fi

    echo "Paramètres PostgreSQL validés avec succès." | tee -a $LOG_FILE
}

# Créer les répertoires de sauvegarde
create_backup_dirs() {
    echo "Création des répertoires de sauvegarde..." | tee -a $LOG_FILE
    mkdir -p $BACKUP_DIR
    mkdir -p $WAL_ARCHIVE_DIR
    chown -R postgres:postgres $BACKUP_DIR
    chown -R postgres:postgres $WAL_ARCHIVE_DIR
}

# Sauvegarde de base avec pg_basebackup
perform_base_backup() {
    echo "Début de la sauvegarde de base avec pg_basebackup..." | tee -a $LOG_FILE
    pg_basebackup -h $PG_HOST -p $PG_PORT -U $PG_USER -D $BACKUP_DIR/$BACKUP_NAME -Ft -z -P -Xs -R -C -S standby_$DATE >> $LOG_FILE 2>&1

    if [ $? -ne 0 ]; then
        echo "ERREUR : La sauvegarde de base a échoué." | tee -a $LOG_FILE
        exit 1
    fi

    echo "Sauvegarde de base terminée avec succès : $BACKUP_DIR/$BACKUP_NAME" | tee -a $LOG_FILE
}

# Vérification de la sauvegarde
verify_backup() {
    echo "Vérification de la sauvegarde..." | tee -a $LOG_FILE
    if [ ! -d "$BACKUP_DIR/$BACKUP_NAME" ]; then
        echo "ERREUR : Le répertoire de sauvegarde n'existe pas." | tee -a $LOG_FILE
        exit 1
    fi

    # Vérifier la présence des fichiers WAL dans l'archive
    wal_files=$(ls $WAL_ARCHIVE_DIR | wc -l)
    if [ "$wal_files" -eq 0 ]; then
        echo "ATTENTION : Aucun fichier WAL archivé trouvé. Le PITR ne sera pas possible." | tee -a $LOG_FILE
    else
        echo "Fichiers WAL archivés : $wal_files" | tee -a $LOG_FILE
    fi

    echo "Vérification terminée." | tee -a $LOG_FILE
}

# Fonction principale
main() {
    check_pg_parameters
    create_backup_dirs
    perform_base_backup
    verify_backup
    echo "Sauvegarde à chaud et configuration PITR terminées avec succès !" | tee -a $LOG_FILE
}

main

