#!/bin/bash
set -euo pipefail

# Variables à adapter
version="15"
PGDATA="/data/pgsql-$version/demopg/data"
PG_BIN="/usr/pgsql-$version/bin"
CLUSTER_NAME="pg_cluster_demo"
DATA_DIR=$PGDATA
NODE_ID=2               # Numéro unique correspondant à ce standby
NODE_NAME=$(hostname)
REPMGR_CONF="/etc/repmgr/$version/repmgr.conf"
REPMGR_USER="repmgr"
PGPORT=5432
PGHOST=10.200.0.100
PRIMARY_NODE_ID=1
REPLICATOR_USER=replicator
REPLICATOR_PASSWORD=replica123
REPMGR_PASSWORD=$REPLICATOR_PASSWORD



# Connexion PostgreSQL pour repmgr
#CONNINFO="host=$PGHOST user=$REPMGR_USER dbname=postgres password=$REPMGR_PASSWORD port=$PGPORT"
CONNINFO="host=10.200.0.100 user=repmgr dbname=postgres password=$REPMGR_PASSWORD port=5432"


echo "Création / modification du fichier $REPMGR_CONF sur standby"

echo "Vérification des droits pour écrire dans $REPMGR_CONF ..."

if [ ! -w "$(dirname $REPMGR_CONF)" ]; then
  echo "Pas assez de droits, utilisation de sudo pour écrire le fichier repmgr.conf"
  tee $REPMGR_CONF > /dev/null <<EOF
#cluster=$CLUSTER_NAME
node_id=$NODE_ID
node_name=$NODE_NAME
conninfo='$CONNINFO'
data_directory='$DATA_DIR'
failover=manual
promote_command='repmgr standby promote -f $REPMGR_CONF'
follow_command='repmgr standby follow -f $REPMGR_CONF --sleep-interval 2'
#retry_delay=5
log_level=INFO
EOF
else
  echo "Ecriture directe du fichier repmgr.conf"
  cat >$REPMGR_CONF <<EOF
#cluster=$CLUSTER_NAME
node_id=$NODE_ID
node_name=$NODE_NAME
conninfo='$CONNINFO'
data_directory='$DATA_DIR'
failover=manual
promote_command='repmgr standby promote -f $REPMGR_CONF'
follow_command='repmgr standby follow -f $REPMGR_CONF --sleep-interval 2'
#retry_delay=5
log_level=INFO
EOF
fi


if [ -d "$DATA_DIR" ] && [ "$(ls -A $DATA_DIR)" ]; then
echo "Vérification ou création rôle $REPMGR_USER..."
if $PG_BIN/psql -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$REPMGR_USER'" | grep -q 1; then
  echo "Rôle $REPMGR_USER déjà présent."
else
  $PG_BIN/psql -U postgres -c "CREATE ROLE $REPMGR_USER WITH LOGIN REPLICATION PASSWORD '$REPMGR_PASSWORD';"
  echo "Rôle $REPMGR_USER créé."
fi
fi


# Nettoyer le répertoire PGDATA avant clone
if [ -d "$DATA_DIR" ] && [ "$(ls -A $DATA_DIR)" ]; then
  echo "Nettoyage du répertoire $DATA_DIR avant pg_basebackup clone."
  rm -rf "$DATA_DIR"/*
fi

echo "Clonage du primaire via repmgr standby clone..."
#$PG_BIN/repmgr -f $REPMGR_CONF standby clone --force --host=$PGHOST --ssh-options='-o StrictHostKeyChecking=no'
$PG_BIN/repmgr -f $REPMGR_CONF standby clone --force --host=$PGHOST


echo "Enregistrement du standby dans le cluster repmgr..."
$PG_BIN/repmgr -f $REPMGR_CONF standby register

echo "Redémarrage PostgreSQL..."
$PG_BIN/pg_ctl -D $DATA_DIR restart

echo "Configuration repmgr du standby terminée."

echo "Status du cluster PostgreSQL..."
$PG_BIN/repmgr cluster show