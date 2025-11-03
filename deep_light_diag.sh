#!/bin/bash
# Script d'analyse PostgreSQL rapide

# Basculer vers l'utilisateur postgres
sudo su - postgres << 'EOF'

echo "=== ANALYSE POSTGRESQL RAPIDE ==="

# Vérification des instances
echo "1. Instances PostgreSQL en cours :"
ps aux | grep postmaster | grep -v grep

# Sessions et connexions
echo -e "\n2. Sessions actives :"
psql -c "SELECT count(*) as active_sessions FROM pg_stat_activity WHERE datname IS NOT NULL;"

echo -e "\n3. Limite de connexions :"
psql -c "SELECT name, setting FROM pg_settings WHERE name='max_connections';"

# Requêtes longues
echo -e "\n4. Requêtes longues (> 10 min) :"
psql -c "SELECT pid, now() - query_start as duration, query FROM pg_stat_activity WHERE state='active' AND (now() - query_start) > '10 minutes'::interval;"

# Verrous
echo -e "\n5. Verrous en attente :"
psql -c "SELECT count(*) FROM pg_locks WHERE NOT granted;"

# Espace disque des bases
echo -e "\n6. Espace des bases de données :"
psql -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) as size FROM pg_database ORDER BY pg_database_size(datname) DESC;"

EOF

# Vérifications système (en root)
echo -e "\n7. Ressources système :"
echo "Mémoire :"
free -h
echo -e "\nEspace disque :"
df -h /var/lib/pgsql /tmp

echo -e "\n=== ANALYSE TERMINÉE ==="