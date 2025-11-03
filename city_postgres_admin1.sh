#!/bin/bash

# Utilitaires basiques
show_menu() {
  echo "-------------------------------"
  echo "    Menu Administration PG     "
  echo "-------------------------------"
  echo "1) Infos Serveur/Postgres"
  echo "2) Exécution d'un script SQL"
  echo "3) Extraction SQL vers CSV"
  echo "4) Sauvegarde (dump)"
  echo "5) Restauration database"
  echo "6) Renommer une database"
  echo "7) Paramètres de performance"
  echo "8) Requêtes + coûteuses"
  echo "9) Vérification SSL"
  echo "10) Occupation disques"
  echo "11) Logs récents"
  echo "12) Versions PostgreSQL"
  echo "13) Réplication & Archives"
  echo "14) Snapshot à chaud"
  echo "15) Détail espace des bases"
  echo "16) Connexions & verrous"
  echo "17) Quitter"
}

select_pg_conf() {
  CONF=$(find /etc /var/lib/pgsql /usr/local/pgsql -name postgresql.conf 2>/dev/null | fzf)
  echo "$CONF"
}

list_databases() {
  sudo -u postgres psql -At -c "SELECT datname FROM pg_database WHERE datistemplate = false;"
}

show_server_info() {
  HOST=$(hostname)
  IP=$(hostname -I | awk '{print $1}')
  sudo -u postgres psql -c "SELECT version();"
  echo "Serveur: $HOST ($IP)"
  sudo -u postgres psql -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'slave' ELSE 'master' END AS status;"
  sudo -u postgres psql -c "SELECT pg_postmaster_start_time();"
  echo "Bases et tailles :"
  sudo -u postgres psql -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database;"
}

execute_sql_script() {
  echo "Bases disponibles :"
  list_databases
  read -p "Nom de la database ? " DB
  SQL=$(ls /tmp/mbu/sql/*.sql | fzf)
  LOG="/tmp/${SQL##*/}.log"
  sudo -u postgres psql -d "$DB" -f "$SQL" | tee "$LOG"
  chmod 777 "$LOG"
  echo "Log généré $LOG"
  read -p "Envoyer le log par scp ? (y/n) " ans
  if [ "$ans" == "y" ]; then
    scp -p "$LOG" user@bastion:/var/log/pg-logs/
  fi
}

extract_csv() {
  echo "Bases disponibles :"
  list_databases
  read -p "Nom de la database ? " DB
  SQL=$(ls /tmp/mbu/sql/*.sql | fzf)
  TMP_TABLE="PASSING_TO_CSV"
  sudo -u postgres psql -d "$DB" -f "$SQL"
  sudo -u postgres psql -d "$DB" -c "\\COPY $TMP_TABLE TO '/tmp/${SQL##*/}.csv' WITH CSV HEADER DELIMITER ';' ENCODING 'UTF8';"
  sudo -u postgres psql -d "$DB" -c "DROP TABLE IF EXISTS $TMP_TABLE;"
  echo "CSV généré /tmp/${SQL##*/}.csv"
}

perform_dump() {
  CONF=$(select_pg_conf)
  echo "Bases disponibles :"
  list_databases
  read -p "Nom de la database à sauvegarder ? (pour tout : <ENTER>) " DB
  read -p "Compression (y/n) ? " COMP
  if [ -z "$DB" ]; then
    F="/tmp/dumpall.sql"
    sudo -u postgres pg_dumpall > "$F"
    [ "$COMP" == "y" ] && gzip "$F"
  else
    F="/tmp/$DB.sql"
    sudo -u postgres pg_dump "$DB" > "$F"
    [ "$COMP" == "y" ] && gzip "$F"
  fi
  echo "Dump généré $F"
  read -p "Envoyer le dump par scp ? (y/n) " ans
  if [ "$ans" == "y" ]; then
    scp -p "$F"* user@bastion:/var/log/pg-backup/
  fi
}

rename_database() {
  echo "Bases disponibles :"
  list_databases
  read -p "Nom de la database à renommer ? " DB
  read -p "Nouveau nom de la database ? " NEWDB
  sudo -u postgres psql -c "ALTER DATABASE \"$DB\" RENAME TO \"$NEWDB\";"
  list_databases
}

show_performance_params() {
  sudo -u postgres psql -c "SHOW ALL;"
}

show_expensive_queries() {
  sudo -u postgres psql -d postgres -c "
    SELECT query, calls, total_time, rows
    FROM pg_stat_statements
    ORDER BY total_time DESC
    LIMIT 10;"
}

check_ssl_config() {
  sudo -u postgres psql -c "SHOW ssl;"
  sudo -u postgres psql -c "SHOW ssl_cert_file;"
  sudo -u postgres psql -c "SHOW ssl_key_file;"
}

check_fs_occupancy() {
  df -h | awk '$5+0 > 80'
}

show_recent_logs() {
  echo "Logs système :"
  dmesg | tail -n 20
  echo "Logs Postgres :"
  journalctl -u postgresql | tail -n 20
}

list_postgres_versions() {
  pg_lsclusters
}

check_replication_and_archives() {
  sudo -u postgres psql -c "SELECT * FROM pg_stat_replication;"
  sudo -u postgres psql -c "SHOW archive_mode;"
  sudo -u postgres psql -c "SHOW archive_command;"
}

perform_hot_snapshot() {
  echo "Exemple LVM snapshot, adapter selon infrastructure:"
  lvcreate -L1G -s -n pg_snapshot /dev/vg0/postgresql
  echo "Snapshot créé: /dev/vg0/pg_snapshot"
}

show_db_space_details() {
  sudo -u postgres psql -c "
    SELECT datname,
      pg_size_pretty(pg_database_size(datname)) AS size
    FROM pg_database
    WHERE datistemplate = false;"
}

list_active_connections_locks() {
  sudo -u postgres psql -c "SELECT * FROM pg_locks;"
  sudo -u postgres psql -c "SELECT * FROM pg_stat_activity;"
}

# Menu principal
while true; do
  show_menu
  read -p "Choix: " CH
  case $CH in
    1) show_server_info ;;
    2) execute_sql_script ;;
    3) extract_csv ;;
    4) perform_dump ;;
    5) echo "Restaurer : pg_restore ou psql -f <dump> [database]" ;;
    6) rename_database ;;
    7) show_performance_params ;;
    8) show_expensive_queries ;;
    9) check_ssl_config ;;
    10) check_fs_occupancy ;;
    11) show_recent_logs ;;
    12) list_postgres_versions ;;
    13) check_replication_and_archives ;;
    14) perform_hot_snapshot ;;
    15) show_db_space_details ;;
    16) list_active_connections_locks ;;
    17) exit ;;
    *) echo "Choix incorrect" ;;
  esac
done

