#!/bin/bash

CONTAINER=pro093sql110
PGDATA="/data/pgsql-15/demopg/data"
POSTGRES_CONF="$PGDATA/postgresql.conf"
PG_HBA="$PGDATA/pg_hba.conf"
PG_BIN="/usr/pgsql-15/bin"

POSTGRES_CONF=$PGDATA/postgresql.conf
PGHBA_CONF=$PGDATA/pg_hba.conf
PRIMARY_HOST=10.200.0.100
REPLICATOR_USER=replicator
REPLICATOR_PASSWORD=replica123

REPLICAT_CONTAINER=pro093sql110
MASTER_HOST=$PRIMARY_HOST
PORT=5432

PGUSER="postgres"
PGDB="postgres"


#!/bin/bash

PGUSER="postgres"
PGDATABASE="postgres"

echo "=== Audit automatique PostgreSQL Instance $(hostname) ==="

# 1. Version et binaire
echo -e "\n-- Version PostgreSQL :"
$PG_BIN/psql -U $PGUSER -d $PGDATABASE -c "SELECT version();"

# 2. Rôle du serveur
echo -e "\n-- Rôle de l'instance :"
$PG_BIN/psql -U $PGUSER -d $PGDATABASE -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'Réplicat (standby)' ELSE 'Primaire' END AS rôle_instance;"

# 3. Paramètres cluster et réplication
echo -e "\n-- Paramètres cluster, réplication et HA :"
$PG_BIN/psql -U $PGUSER -d $PGDATABASE -c "SHOW wal_level;"
$PG_BIN/psql -U $PGUSER -d $PGDATABASE -c "SHOW synchronous_commit;"
$PG_BIN/psql -U $PGUSER -d $PGDATABASE -c "SHOW synchronous_standby_names;"
$PG_BIN/psql -U $PGUSER -d $PGDATABASE -c "SHOW max_wal_senders;"
$PG_BIN/psql -U $PGUSER -d $PGDATABASE -c "SHOW archive_mode;"

# 4. Découverte des nœuds (primaire)
echo -e "\n-- Connexions de réplication connues :"
$PG_BIN/psql -U $PGUSER -d $PGDATABASE -c "SELECT application_name, client_addr, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;"

# 5. Découverte des nœuds (réplicat)
#echo -e "\n-- Source du flux maître (si standby) :"
#$PG_BIN/psql -U $PGUSER -d $PGDATABASE -c "SELECT status, sender_host, sender_port, receiver_start_lsn, receiver_last_msg_send_time FROM pg_stat_wal_receiver;"
echo -e "\n-- Source du flux maître (si standby) :"
psql -U $PGUSER -d $PGDATABASE -c "SELECT status, receiver_host, receiver_port, receive_start_lsn, receive_start_tli, received_lsn, received_tli, last_msg_send_time, last_msg_receipt_time FROM pg_stat_wal_receiver;"



# 6. Liste des fichiers signal/failover (standby)
echo -e "\n-- Fichiers signal haute dispo/rôle :"
ls $PGDATA/standby.signal $PGDATA/recovery.signal $PGDATA/promote.signal 2>/dev/null

# 7. Timeline WAL courante
echo -e "\n-- Timeline WAL :"
$PG_BIN/psql -U $PGUSER -d $PGDATABASE -c "SELECT timeline_id FROM pg_control_checkpoint;"

# 8. Activité HA (repmgr, patroni, ... versions docker/kube)
echo -e "\n-- Recherche de processus repmgr, patroni, etc. (haute dispo logicielle) :"
ps aux | grep -E 'repmgr|patroni|pg_auto_failover|etcd|consul' | grep -v grep

# 9. Vérification rapide service/ressources
echo -e "\n-- Etat du service postgres :"
$PG_BIN/pg_isready

# 10. Résumé et conseils
echo -e "\n=== Synthèse automatique ==="
$PG_BIN/pg_isready | grep "accepting connections" >/dev/null && echo "Service PostgreSQL UP" || echo "Service PostgreSQL DOWN"
$PG_BIN/psql -U $PGUSER -d $PGDATABASE -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'NOEUD STANDBY' ELSE 'NOEUD PRIMAIRE' END AS audit_rôle;"
