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

info() {
  echo -e "\n==== $1 ===="
}

# 1. Rôle de l'instance
info "Rôle de l'instance (primaire ou réplicat)"
psql -U $PGUSER -d $PGDB -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'réplicat (standby)' ELSE 'primaire' END AS rôle_instance;"

# 2. Etat de la réplication (sur le primaire)
info "Etat des flux de réplication (primaire seulement)"
psql -U $PGUSER -d $PGDB -c "SELECT pid, usename, application_name, client_addr, state, sync_state FROM pg_stat_replication;"

# 3. Débit reçu/rejoué (sur un réplicat)
info "WAL reçu/rejoué (réplicat seulement)"
psql -U $PGUSER -d $PGDB -c "SELECT pg_last_wal_receive_lsn() AS dernière_position_reçue, pg_last_wal_replay_lsn() AS dernière_position_rejouée;"

# 4. Retard WAL sur le réplicat
info "Décalage WAL reçu/rejoué en octets (réplicat seulement)"
psql -U $PGUSER -d $PGDB -c "SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS retard_octets;"

# 5. Timestamp dernière transaction rejouée (réplicat seulement)
info "Date/heure dernière transaction rejouée (réplicat seulement)"
psql -U $PGUSER -d $PGDB -c "SELECT pg_last_xact_replay_timestamp() AS dernière_transaction_rejouée;"

# 6. Walsender non streaming (erreurs primaires)
info "Flux de réplication non streaming (primaire : anomalies éventuelles)"
psql -U $PGUSER -d $PGDB -c "SELECT * FROM pg_stat_activity WHERE backend_type = 'walsender' AND state <> 'streaming';"

# 7. Timeline courante
info "Timeline WAL courante"
#psql -U $PGUSER -d $PGDB -c "SELECT timeline_id, pg_control_checkpoint()->>'last_system_wal_flush_lsn' AS last_wal FROM pg_control_checkpoint();"

#psql -U $PGUSER -d $PGDB -c "SELECT timeline_id FROM pg_control_system();"

psql -U postgres -c "SELECT timeline_id FROM pg_control_checkpoint();"


echo -e "\nAnalyse manuelle recommandée :"
echo "-- Sur le primaire, surveiller que tous les state=streaming (pg_stat_replication)."
echo "-- Sur le réplicat, vérifiez que le retard WAL est faible et que pg_last_xact_replay_timestamp() évolue."
echo "-- Si 'retard_octets' est élevé ou bloqué, ou si walsender n'est pas 'streaming' : investiguer logs et réseau."
