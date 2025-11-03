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

echo "----- Préparation du serveur réplicat PostgreSQL -----"


# Fonction pour tester la connectivité TCP sur un port donné depuis un container docker
check_port_access() {
  local host=$1
  local port=$2
  local container=$3

  echo "Test de connexion TCP sur $host:$port depuis le container $container"
  echo "nc -z -w3 $host $port"
  nc -z -w3 $host $port
  if [ $? -ne 0 ]; then
    echo "ERREUR : Le port $port sur $host n'est pas accessible depuis $container. Abandon."
    exit 1
  else
    echo "Succès : Port $port accessible."
  fi
}


# Fonction pour vérifier et modifier un paramètre dans postgresql.conf
checkandsetconf() {
  local param=$1
  local value=$2
  local file=$3

  current=$(grep -E "^${param}[ \t]*=" $file | awk -F= '{print $2}' | tr -d ' ')
  echo "Paramètre $param actuel: $current"
  if [[ "$current" != "$value" ]]; then
    echo "Mise à jour du paramètre $param à $value"
   bash -c "sed -i '/^${param}[ \t]*=/d' $file"
   bash -c "echo \"$param = $value\" >> $file"
  else
    echo "Paramètre $param déjà correctement configuré"
  fi
}

echo "# Test de connectivité préalable"
check_port_access $MASTER_HOST $PORT $REPLICAT_CONTAINER


echo ""
echo "1. Arrêt du serveur PostgreSQL sur le réplicat"
#docker-compose exec -u postgres $CONTAINER pg_ctl -D $PGDATA stop -m fast || true
#docker exec -u postgres $CONTAINER pg_ctl -D $PGDATA stop -m fast

#docker-compose exec -u postgres $CONTAINER pg_ctl -D $PGDATA stop -m smart
echo "pg_ctl -D $PGDATA stop -m immediate"
$PG_BIN/pg_ctl -D $PGDATA stop -m immediate


sleep 10

echo ""
echo "2. Nettoyage du répertoire PGDATA"
echo "rm -rf /data/pgsql-15/demopg/data/*" 
rm -rf /data/pgsql-15/demopg/data/*

echo ""
echo "3. Lancement de pg_basebackup pour synchroniser avec le primaire"
echo "pg_basebackup -h $PRIMARY_HOST -D $PGDATA -U $REPLICATOR_USER -v -P --wal-method=stream"
#docker-compose exec $CONTAINER pg_basebackup -h $PRIMARY_HOST -D $PGDATA -U $REPLICATOR_USER -v -P --wal-method=stream
sh -c "PGPASSWORD=$REPLICATOR_PASSWORD pg_basebackup -h $PRIMARY_HOST -D $PGDATA -U $REPLICATOR_USER -v -P --wal-method=stream"


echo ""
echo "4. Mise à jour des paramètres de configuration"
echo "4.1 Mise en place du fichier pg_hba.conf pour accès réplication"
echo "bash -c \"echo 'host replication $REPLICATOR_USER samenet md5' >> $PGHBA_CONF\""
bash -c "echo 'host replication $REPLICATOR_USER samenet md5' >> $PGHBA_CONF"


echo ""
echo "4.2 Mise à jour des paramètres essentiels dans postgresql.conf"
checkandsetconf hot_standby on $POSTGRES_CONF
checkandsetconf primary_conninfo "'host=$PRIMARY_HOST user=$REPLICATOR_USER password=$REPLICATOR_PASSWORD'" $POSTGRES_CONF
checkandsetconf wal_level replica $POSTGRES_CONF
checkandsetconf max_wal_senders 10 $POSTGRES_CONF
checkandsetconf max_replication_slots 10 $POSTGRES_CONF
checkandsetconf wal_keep_size 64MB $POSTGRES_CONF
checkandsetconf wal_log_hints on $POSTGRES_CONF

echo ""
echo "4.3 Création de standby.signal (PostgreSQL 12+) pour activer mode standby"
echo "bash -c "touch $PGDATA/standby.signal""
bash -c "touch $PGDATA/standby.signal"

echo ""
echo "5. Démarrage du serveur PostgreSQL en mode réplication"
$PG_BIN/pg_ctl -D $PGDATA start
#echo "docker-compose restart $CONTAINER"
#docker-compose restart $CONTAINER

echo ""
echo "6. Vérification du rôle du serveur"
# Monitoring PostgreSQL pro093sql110
echo "Informations sur la base pro093sql110:"
sleep 20
echo "liste sur pro093sql110:"
psql -U postgres -c "\l"
psql -U postgres -c "SELECT datname, usename, application_name, client_addr, state FROM pg_stat_activity;"
psql -U postgres -c "SELECT version();"
psql -U postgres -c "SELECT * FROM pg_locks WHERE NOT granted;"



echo "Statut du rôle sur pro075sql100 (primaire ou réplica) :"
psql -U postgres -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'réplicat (standby)' ELSE 'primaire' END AS rôle_instance;"

echo "Statut du rôle sur pro093sql110 (primaire ou réplica) :"
psql -U postgres -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'réplicat (standby)' ELSE 'primaire' END AS rôle_instance;"

