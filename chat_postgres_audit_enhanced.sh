#!/bin/bash

# Configuration
PG_HOST="localhost"
PG_PORT="5432"
PG_USER="postgres"
PG_PASSWORD="votre_mot_de_passe"
OUTPUT_DIR="./postgres_audit_enhanced"
REPORT_FILE="$OUTPUT_DIR/postgres_audit_report_$(date +%Y%m%d_%H%M%S).html"

# Créer le dossier de sortie
mkdir -p "$OUTPUT_DIR"

# Collecte des informations système
echo "Collecte des informations système..."
SYSTEM_INFO="$OUTPUT_DIR/system_info.txt"
{
    echo "=== Informations Système ==="
    uname -a
    echo -e "\n=== Version OS ==="
    cat /etc/redhat-release
    echo -e "\n=== CPU ==="
    lscpu
    echo -e "\n=== Mémoire ==="
    free -h
    echo -e "\n=== Disques ==="
    df -h
    echo -e "\n=== Swap ==="
    swapon --show
    echo -e "\n=== Uptime ==="
    uptime
    echo -e "\n=== Environnement (Docker/Kubernetes/Cluster) ==="
    if [ -f /.dockerenv ]; then
        echo "Environnement : Docker"
        docker ps
    elif [ -f /etc/kubernetes/kubelet.conf ]; then
        echo "Environnement : Kubernetes"
        kubectl get pods -n default
    else
        echo "Environnement : Bare Metal ou VM"
    fi
} > "$SYSTEM_INFO"

# Collecte des informations PostgreSQL
echo "Collecte des informations PostgreSQL..."
PG_INFO="$OUTPUT_DIR/postgres_info.sql"
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "postgres" -c "
    \o $PG_INFO

    -- Version de PostgreSQL
    SELECT version();

    -- Paramètres de configuration
    SHOW ALL;

    -- Liste des bases de données
    SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
    FROM pg_database
    ORDER BY pg_database_size(datname) DESC;

    -- Connexions actives
    SELECT usename, application_name, client_addr, state, query
    FROM pg_stat_activity;

    -- Tables les plus volumineuses
    SELECT nspname || '.' || relname AS table_name,
           pg_size_pretty(pg_total_relation_size(relid)) AS size
    FROM pg_catalog.pg_statio_user_tables
    ORDER BY pg_total_relation_size(relid) DESC
    LIMIT 20;

    -- Index les plus volumineux
    SELECT schemaname || '.' || tablename || '.' || indexname AS index_name,
           pg_size_pretty(pg_relation_size(quote_ident(schemaname) || '.' || quote_ident(tablename) || '.' || quote_ident(indexname))) AS size
    FROM pg_indexes
    ORDER BY pg_relation_size(quote_ident(schemaname) || '.' || quote_ident(tablename) || '.' || quote_ident(indexname)) DESC
    LIMIT 20;

    -- Requêtes lentes (si pg_stat_statements est activé)
    SELECT query, calls, total_time, mean_time
    FROM pg_stat_statements
    ORDER BY mean_time DESC
    LIMIT 20;

    -- Verrous
    SELECT locktype, relation::regclass, mode, transactionid AS tid, virtualtransaction AS vtid, pid, usename, query
    FROM pg_locks
    LEFT JOIN pg_stat_activity ON pg_locks.pid = pg_stat_activity.pid;

    -- Cache hit ratio
    SELECT sum(heap_blks_read) AS heap_read,
           sum(heap_blks_hit) AS heap_hit,
           sum(heap_blks_hit) / (sum(heap_blks_hit) + sum(heap_blks_read) + 0.00001) AS hit_ratio
    FROM pg_statio_user_tables;

    -- Statistiques d'autovacuum
    SELECT schemaname, relname, last_autovacuum, n_dead_tup
    FROM pg_stat_all_tables
    WHERE n_dead_tup > 0
    ORDER BY n_dead_tup DESC
    LIMIT 20;

    -- Sauvegardes (WAL archiving)
    SHOW archive_mode;
    SHOW archive_command;
    SELECT * FROM pg_stat_archiver;

    -- Réplication
    SELECT * FROM pg_stat_replication;
    SELECT * FROM pg_stat_wal_receiver;

    -- Sécurité : Rôles et permissions
    SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolcanlogin, rolreplication, rolbypassrls
    FROM pg_roles
    ORDER BY rolname;

    SELECT grantee, privilege_type, table_name
    FROM information_schema.role_table_grants
    ORDER BY grantee, table_name;

    -- Sécurité : Chiffrement
    SHOW ssl;
    SHOW password_encryption;

    \o
" > /dev/null

# Génération du rapport HTML
echo "Génération du rapport HTML..."
PYTHON_SCRIPT="$OUTPUT_DIR/generate_report.py"
cat > "$PYTHON_SCRIPT" << 'EOF'
import psycopg2
from jinja2 import Environment, FileSystemLoader
import os

# Configuration
PG_HOST = "localhost"
PG_PORT = "5432"
PG_USER = "postgres"
PG_PASSWORD = "votre_mot_de_passe"
OUTPUT_DIR = "./postgres_audit_enhanced"
REPORT_FILE = f"{OUTPUT_DIR}/postgres_audit_report_{os.popen('date +%Y%m%d_%H%M%S').read().strip()}.html"

# Connexion à PostgreSQL
conn = psycopg2.connect(
    host=PG_HOST,
    port=PG_PORT,
    user=PG_USER,
    password=PG_PASSWORD,
    database="postgres"
)
cursor = conn.cursor()

# Collecte des données
def get_system_info():
    with open(f"{OUTPUT_DIR}/system_info.txt", "r") as f:
        return f.read()

def get_postgres_info():
    with open(f"{OUTPUT_DIR}/postgres_info.sql", "r") as f:
        return f.read()

# Génération du rapport HTML
env = Environment(loader=FileSystemLoader('.'))
template = env.get_template('report_template_enhanced.html')

report_data = {
    "system_info": get_system_info(),
    "postgres_info": get_postgres_info(),
}

with open(REPORT_FILE, "w") as f:
    f.write(template.render(report_data))

print(f"Rapport généré : {REPORT_FILE}")
EOF

# Template HTML enrichi
cat > "$OUTPUT_DIR/report_template_enhanced.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Rapport d'Audit PostgreSQL (Sauvegardes, Réplication, Sécurité)</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #333; }
        h2 { color: #444; }
        pre { background: #f4f4f4; padding: 10px; border-radius: 5px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background: #f2f2f2; }
        .warning { color: red; }
        .ok { color: green; }
    </style>
</head>
<body>
    <h1>Rapport d'Audit PostgreSQL</h1>

    <h2>1. Informations Système</h2>
    <pre>{{ system_info }}</pre>

    <h2>2. Informations PostgreSQL</h2>
    <pre>{{ postgres_info }}</pre>

    <h2>3. Sauvegardes</h2>
    <p>Statut de l'archivage WAL et des sauvegardes automatiques.</p>

    <h2>4. Réplication</h2>
    <p>Statut des réplicas et retard de réplication.</p>

    <h2>5. Sécurité</h2>
    <p>Rôles, permissions, chiffrement SSL, et accès réseau.</p>

    <h2>6. Recommandations</h2>
    <ul>
        <li>Vérifier les paramètres <code>shared_buffers</code>, <code>work_mem</code>, et <code>maintenance_work_mem</code> pour optimiser la mémoire.</li>
        <li>Surveiller les requêtes lentes avec <code>pg_stat_statements</code>.</li>
        <li>Vérifier les verrous bloquants avec <code>pg_locks</code>.</li>
        <li>Optimiser les index sur les tables volumineuses.</li>
        <li>Planifier des <code>VACUUM FULL</code> ou <code>ANALYZE</code> si nécessaire.</li>
        <li>Activer <code>archive_mode</code> et configurer <code>archive_command</code> pour les sauvegardes.</li>
        <li>Vérifier la réplication avec <code>pg_stat_replication</code>.</li>
        <li>Renforcer la sécurité : désactiver les rôles inutiles, activer SSL, chiffrer les mots de passe.</li>
    </ul>
</body>
</html>
EOF

# Exécution du script Python
python3 "$PYTHON_SCRIPT"

# Nettoyage
rm "$PYTHON_SCRIPT"

echo "Audit terminé. Rapport généré : $REPORT_FILE"

