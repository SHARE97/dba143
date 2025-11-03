#!/bin/bash

version="15"
PGDATA="/data/pgsql-$version/demopg/data"
POSTGRES_CONF="$PGDATA/postgresql.conf"
PG_HBA="$PGDATA/pg_hba.conf"
PG_BIN="/usr/pgsql-$version/bin"

POSTGRES_CONF=$PGDATA/postgresql.conf
PGHBA_CONF=$PGDATA/pg_hba.conf
PRIMARY_HOST=10.200.0.100
REPLICATOR_USER=replicator
REPLICATOR_PASSWORD=replica123
REPLICAT_CONTAINER=pro093sql110
MASTER_HOST=$PRIMARY_HOST

PGUSER="postgres"
PGDB="postgres"


# Variables à adapter
CLUSTER_NAME="pg_cluster_demo"
NODE_ID=1               # Numéro unique de ce nœud
NODE_NAME=$(hostname)
DATA_DIR=$PGDATA
REPMGR_CONF="/etc/repmgr/$version/repmgr.conf"
REPMGR_USER="repmgr"
REPMGR_PASSWORD=$REPLICATOR_PASSWORD
PGPORT=5432
PGHOST="localhost"

# Connexion PostgreSQL pour repmgr
CONNINFO="host=$PGHOST user=$REPMGR_USER dbname=$PGDB password=$REPMGR_PASSWORD port=$PGPORT"
echo $CONNINFO
echo ""
echo "Création / modification du fichier $REPMGR_CONF"


echo "Vérification des droits pour écrire dans $REPMGR_CONF ..."

if [ ! -w "$(dirname $REPMGR_CONF)" ]; then
  echo "Pas assez de droits, utilisation de sudo pour écrire le fichier repmgr.conf"
  tee $REPMGR_CONF > /dev/null <<EOF
cluster=$CLUSTER_NAME
node_id=$NODE_ID
node_name=$NODE_NAME
conninfo='$CONNINFO'
data_directory='$DATA_DIR'
failover=manual
promote_command='repmgr standby promote -f $REPMGR_CONF'
follow_command='repmgr standby follow -f $REPMGR_CONF --sleep-interval 2'
retry_delay=5
log_level=INFO
EOF
else
  echo "Ecriture directe du fichier repmgr.conf"
  cat >$REPMGR_CONF <<EOF
cluster=$CLUSTER_NAME
node_id=$NODE_ID
node_name=$NODE_NAME
conninfo='$CONNINFO'
data_directory='$DATA_DIR'
failover=manual
promote_command='repmgr standby promote -f $REPMGR_CONF'
follow_command='repmgr standby follow -f $REPMGR_CONF --sleep-interval 2'
retry_delay=5
log_level=INFO
EOF
fi

ls -l $REPMGR_CONF


echo "Vérification si rôle $REPMGR_USER existe..."
if $PG_BIN/psql -U $PGUSER -tAc "SELECT 1 FROM pg_roles WHERE rolname='$REPMGR_USER'" | grep -q 1; then
  echo "Rôle $REPMGR_USER existe déjà."
else
  echo "Création du rôle $REPMGR_USER avec droits REPLICATION."
  $PG_BIN/psql -U $PGUSER -c "CREATE ROLE $REPMGR_USER WITH LOGIN REPLICATION PASSWORD '$REPMGR_PASSWORD';"
fi


# Vérifier si ligne déjà présente
if ! grep -q "host repmgr $REPMGR_USER samenet md5" $PGHBA_CONF; then
  echo "Ajout règle pg_hba.conf pour repmgr"
  echo "host repmgr $REPMGR_USER 0.0.0.0/0 md5" >> $PGHBA_CONF
else
  echo "Règle pg_hba.conf pour repmgr déjà présente"
fi


echo "Enregistrement du nœud courant en tant que primaire dans repmgr..."
$PG_BIN/repmgr -f $REPMGR_CONF primary register -U $PGUSER -S $PGDB


echo "Fin de la configuration repmgr. Redémarrage du service PostgreSQL recommandé."

echo "Redémarrage PostgreSQL..."
$PG_BIN/pg_ctl -D $DATA_DIR restart

echo "Status du cluster PostgreSQL..."
$PG_BIN/repmgr cluster show
