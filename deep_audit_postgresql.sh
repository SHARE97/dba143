#!/bin/bash

# Script d'audit PostgreSQL - Rapport HTML
# Usage: ./audit_postgresql.sh [output_directory]

set -e

# Configuration
DB_USER="${PGUSER:-postgres}"
DB_HOST="${PGHOST:-localhost}"
DB_PORT="${PGPORT:-5432}"
OUTPUT_DIR="${1:-./postgres_audit_$(date +%Y%m%d_%H%M%S)}"
HTML_FILE="$OUTPUT_DIR/audit_report.html"
SQL_DIR="$OUTPUT_DIR/sql"
DATA_DIR="$OUTPUT_DIR/data"

# Couleurs pour le logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Fonctions de logging
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Vérification des prérequis
check_prerequisites() {
    log_info "Vérification des prérequis..."
    
    if ! command -v psql &> /dev/null; then
        log_error "psql n'est pas installé ou n'est pas dans le PATH"
        exit 1
    fi
    
    if ! psql -lqt -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" 2>/dev/null | grep -q .; then
        log_error "Impossible de se connecter à PostgreSQL avec l'utilisateur $DB_USER"
        exit 1
    fi
    
    log_info "Prérequis vérifiés avec succès"
}

# Création des répertoires
create_directories() {
    mkdir -p "$OUTPUT_DIR" "$SQL_DIR" "$DATA_DIR"
    log_info "Répertoire de sortie créé: $OUTPUT_DIR"
}

# Fonction pour exécuter une requête et sauvegarder le résultat
execute_query() {
    local query_name="$1"
    local query="$2"
    local output_file="$DATA_DIR/${query_name}.csv"
    
    log_info "Exécution de: $query_name"
    
    psql -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d postgres \
        -c "COPY ($query) TO STDOUT WITH CSV HEADER" > "$output_file" 2>/dev/null || {
        log_warn "Échec de la requête: $query_name"
        echo "ERROR" > "$output_file"
    }
}

# Collection des données d'audit
collect_audit_data() {
    log_info "Début de la collecte des données d'audit..."
    
    # 1. Informations système et version
    execute_query "system_info" "
    SELECT 
        name as parametre,
        setting as valeur,
        unit as unite,
        short_desc as description
    FROM pg_settings 
    WHERE name IN ('version', 'server_version', 'server_version_num', 'port', 'data_directory')
    "
    
    # 2. Informations sur les bases de données
    execute_query "database_info" "
    SELECT 
        datname as database,
        datdba as proprietaire,
        encoding as encodage,
        datcollate as collation,
        datctype as ctype,
        datallowconn as connexion_autorisee,
        datconnlimit as limite_connexions,
        pg_size_pretty(pg_database_size(datname)) as taille,
        age(datfrozenxid) as age_xid
    FROM pg_database 
    WHERE datistemplate = false
    ORDER BY pg_database_size(datname) DESC
    "
    
    # 3. Statistiques des tables
    execute_query "table_statistics" "
    SELECT 
        schemaname as schema,
        relname as table,
        n_live_tup as lignes,
        n_dead_tup as lignes_mortes,
        round(n_dead_tup::numeric / GREATEST(n_live_tup, 1) * 100, 2) as pourcentage_mort,
        last_vacuum as dernier_vacuum,
        last_autovacuum as dernier_autovacuum,
        last_analyze as dernier_analyze,
        last_autoanalyze as dernier_autoanalyze,
        pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) as taille
    FROM pg_stat_user_tables 
    ORDER BY n_dead_tup DESC, pg_relation_size(schemaname||'.'||relname) DESC
    "
    
    # 4. Index et performances
    execute_query "index_info" "
    SELECT 
        schemaname as schema,
        relname as table,
        indexrelname as index,
        idx_scan as scans,
        idx_tup_read as tuples_lus,
        idx_tup_fetch as tuples_recuperes,
        pg_size_pretty(pg_relation_size(indexrelid)) as taille_index
    FROM pg_stat_user_indexes 
    ORDER BY idx_scan DESC
    "
    
    # 5. Connexions actives
    execute_query "active_connections" "
    SELECT 
        datname as database,
        usename as utilisateur,
        application_name as application,
        client_addr as adresse_client,
        state as etat,
        query_start as debut_requete,
        state_change as dernier_changement,
        query as requete
    FROM pg_stat_activity 
    WHERE state IS NOT NULL 
    ORDER BY datname, usename
    "
    
    # 6. Verrous actifs
    execute_query "active_locks" "
    SELECT 
        datname as database,
        relname as relation,
        mode as type_verrou,
        granted as accorde,
        usename as utilisateur,
        query as requete
    FROM pg_locks l
    LEFT JOIN pg_database d ON (l.database = d.oid)
    LEFT JOIN pg_class c ON (l.relation = c.oid)
    LEFT JOIN pg_stat_activity a ON (l.pid = a.pid)
    WHERE l.relation IS NOT NULL
    "
    
    # 7. Configuration du serveur
    execute_query "server_config" "
    SELECT 
        name as parametre,
        setting as valeur_actuelle,
        unit as unite,
        pending_restart as redemarrage_requis,
        context as contexte,
        vartype as type,
        min_val as valeur_min,
        max_val as valeur_max,
        enumvals as valeurs_enum,
        boot_val as valeur_boot,
        reset_val as valeur_reset,
        source as source,
        short_desc as description
    FROM pg_settings 
    ORDER BY context, name
    "
    
    # 8. Réplication (si activée)
    execute_query "replication_info" "
    SELECT 
        application_name,
        client_addr,
        state,
        sync_state,
        write_lag,
        flush_lag,
        replay_lag,
        sync_priority
    FROM pg_stat_replication
    "
    
    # 9. Taille des bases de données détaillée
    execute_query "database_sizes" "
    SELECT 
        datname as database,
        pg_size_pretty(pg_database_size(datname)) as taille_totale,
        pg_size_pretty(pg_database_size(datname) - pg_total_relation_size('pg_catalog.pg_class')) as taille_donnees,
        pg_size_pretty(pg_total_relation_size('pg_catalog.pg_class')) as taille_systeme
    FROM pg_database 
    WHERE datistemplate = false
    ORDER BY pg_database_size(datname) DESC
    "
    
    # 10. Statistiques WAL
    execute_query "wal_info" "
    SELECT 
        checkpoints_timed as checkpoints_planifies,
        checkpoints_req as checkpoints_demandes,
        checkpoint_write_time as temps_ecriture_checkpoint,
        checkpoint_sync_time as temps_sync_checkpoint,
        buffers_checkpoint as buffers_checkpoint,
        buffers_clean as buffers_nettoyes,
        maxwritten_clean as max_ecritures_nettoyage,
        buffers_backend as buffers_backend,
        buffers_backend_fsync as buffers_backend_fsync,
        buffers_alloc as buffers_alloues,
        stats_reset as stats_reset
    FROM pg_stat_bgwriter
    "
    
    log_info "Collecte des données terminée"
}

# Génération du rapport HTML
generate_html_report() {
    log_info "Génération du rapport HTML..."
    
    cat > "$HTML_FILE" << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Audit PostgreSQL - Rapport Complet</title>
    <style>
        :root {
            --primary-color: #2c3e50;
            --secondary-color: #34495e;
            --accent-color: #3498db;
            --warning-color: #e74c3c;
            --success-color: #27ae60;
            --text-color: #2c3e50;
            --light-bg: #ecf0f1;
            --border-color: #bdc3c7;
        }
        
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            line-height: 1.6;
            color: var(--text-color);
            background-color: var(--light-bg);
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        
        header {
            background: linear-gradient(135deg, var(--primary-color), var(--secondary-color));
            color: white;
            padding: 2rem 0;
            text-align: center;
            margin-bottom: 2rem;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }
        
        h1 {
            font-size: 2.5rem;
            margin-bottom: 0.5rem;
        }
        
        .subtitle {
            font-size: 1.2rem;
            opacity: 0.9;
        }
        
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 1.5rem;
            margin-bottom: 2rem;
        }
        
        .card {
            background: white;
            padding: 1.5rem;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            text-align: center;
        }
        
        .card h3 {
            color: var(--secondary-color);
            margin-bottom: 0.5rem;
        }
        
        .card .value {
            font-size: 2rem;
            font-weight: bold;
            color: var(--accent-color);
        }
        
        .card.warning .value {
            color: var(--warning-color);
        }
        
        .card.success .value {
            color: var(--success-color);
        }
        
        .toc {
            background: white;
            padding: 1.5rem;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            margin-bottom: 2rem;
        }
        
        .toc h2 {
            color: var(--primary-color);
            margin-bottom: 1rem;
        }
        
        .toc ul {
            list-style: none;
            columns: 2;
        }
        
        .toc li {
            margin-bottom: 0.5rem;
        }
        
        .toc a {
            color: var(--accent-color);
            text-decoration: none;
            transition: color 0.3s;
        }
        
        .toc a:hover {
            color: var(--primary-color);
            text-decoration: underline;
        }
        
        .section {
            background: white;
            padding: 2rem;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            margin-bottom: 2rem;
        }
        
        .section h2 {
            color: var(--primary-color);
            border-bottom: 2px solid var(--accent-color);
            padding-bottom: 0.5rem;
            margin-bottom: 1.5rem;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 1rem 0;
        }
        
        th, td {
            padding: 0.75rem;
            text-align: left;
            border-bottom: 1px solid var(--border-color);
        }
        
        th {
            background-color: var(--light-bg);
            font-weight: 600;
            color: var(--primary-color);
        }
        
        tr:hover {
            background-color: #f8f9fa;
        }
        
        .warning-row {
            background-color: #fff3cd !important;
        }
        
        .critical-row {
            background-color: #f8d7da !important;
        }
        
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 1rem;
            margin: 1rem 0;
        }
        
        .stat-item {
            background: var(--light-bg);
            padding: 1rem;
            border-radius: 6px;
            border-left: 4px solid var(--accent-color);
        }
        
        .stat-item.warning {
            border-left-color: var(--warning-color);
        }
        
        .stat-item.success {
            border-left-color: var(--success-color);
        }
        
        footer {
            text-align: center;
            margin-top: 3rem;
            padding: 2rem 0;
            color: var(--secondary-color);
            border-top: 1px solid var(--border-color);
        }
        
        @media (max-width: 768px) {
            .toc ul {
                columns: 1;
            }
            
            .summary-cards {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🔍 Audit PostgreSQL</h1>
            <p class="subtitle">Rapport complet d'analyse de performance et de configuration</p>
            <p class="subtitle">Généré le: <span id="generation-date"></span></p>
        </header>
        
        <div class="summary-cards" id="summary-cards">
            <!-- Les cartes de résumé seront générées ici -->
        </div>
        
        <div class="toc">
            <h2>📑 Table des matières</h2>
            <ul id="toc-list">
                <!-- La table des matières sera générée ici -->
            </ul>
        </div>
        
        <main id="report-content">
            <!-- Le contenu du rapport sera généré ici -->
        </main>
        
        <footer>
            <p>Rapport généré automatiquement - Audit PostgreSQL</p>
            <p>© 2024 - Consultant Database PostgreSQL</p>
        </footer>
    </div>

    <script>
        // Données du rapport (seront injectées par le script)
        const reportData = {
EOF

    # Injection des données CSV dans le HTML
    for csv_file in "$DATA_DIR"/*.csv; do
        local query_name=$(basename "$csv_file" .csv)
        echo "            \"$query_name\": \`" >> "$HTML_FILE"
        cat "$csv_file" >> "$HTML_FILE"
        echo "\`," >> "$HTML_FILE"
    done

    cat >> "$HTML_FILE" << 'EOF'
        };

        // Fonction pour parser le CSV
        function parseCSV(csvText) {
            const lines = csvText.trim().split('\n');
            const headers = lines[0].split(',');
            const data = [];
            
            for (let i = 1; i < lines.length; i++) {
                const values = lines[i].split(',');
                const row = {};
                headers.forEach((header, index) => {
                    row[header.trim()] = values[index] ? values[index].trim() : '';
                });
                data.push(row);
            }
            
            return data;
        }

        // Génération des cartes de résumé
        function generateSummaryCards() {
            const summaryContainer = document.getElementById('summary-cards');
            
            // Exemple de cartes (à adapter avec les vraies données)
            const cards = [
                { title: 'Bases de données', value: '0', class: '' },
                { title: 'Tables analysées', value: '0', class: '' },
                { title: 'Connexions actives', value: '0', class: '' },
                { title: 'Taille totale', value: '0', class: '' }
            ];

            // Calcul des vraies valeurs
            try {
                const dbInfo = parseCSV(reportData.database_info || '');
                const tableStats = parseCSV(reportData.table_statistics || '');
                const connections = parseCSV(reportData.active_connections || '');
                const dbSizes = parseCSV(reportData.database_sizes || '');
                
                cards[0].value = dbInfo.length;
                cards[1].value = tableStats.length;
                cards[2].value = connections.length;
                
                // Calcul de la taille totale
                let totalSize = 0;
                dbSizes.forEach(db => {
                    const size = db.taille_totale;
                    if (size && size !== 'ERROR') {
                        const match = size.match(/(\d+\.?\d*)\s*(\w+)/);
                        if (match) {
                            let bytes = parseFloat(match[1]);
                            const unit = match[2].toUpperCase();
                            const units = ['B', 'KB', 'MB', 'GB', 'TB'];
                            const exponent = units.indexOf(unit);
                            if (exponent > -1) {
                                totalSize += bytes * Math.pow(1024, exponent);
                            }
                        }
                    }
                });
                
                // Formatage de la taille totale
                const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
                let sizeIndex = 0;
                while (totalSize >= 1024 && sizeIndex < sizes.length - 1) {
                    totalSize /= 1024;
                    sizeIndex++;
                }
                cards[3].value = totalSize.toFixed(2) + ' ' + sizes[sizeIndex];
                
            } catch (error) {
                console.error('Erreur lors du calcul des résumés:', error);
            }

            summaryContainer.innerHTML = cards.map(card => `
                <div class="card ${card.class}">
                    <h3>${card.title}</h3>
                    <div class="value">${card.value}</div>
                </div>
            `).join('');
        }

        // Génération de la table des matières
        function generateTableOfContents() {
            const tocList = document.getElementById('toc-list');
            const sections = [
                { id: 'system-info', title: '🖥️ Informations Système' },
                { id: 'database-overview', title: '🗃️ Aperçu des Bases de Données' },
                { id: 'table-statistics', title: '📊 Statistiques des Tables' },
                { id: 'index-performance', title: '⚡ Performance des Index' },
                { id: 'active-connections', title: '🔗 Connexions Actives' },
                { id: 'locks-monitoring', title: '🔒 Surveillance des Verrous' },
                { id: 'server-config', title: '⚙️ Configuration du Serveur' },
                { id: 'replication-status', title: '🔄 État de la Réplication' },
                { id: 'storage-analysis', title: '💾 Analyse du Stockage' },
                { id: 'wal-statistics', title: '📝 Statistiques WAL' }
            ];

            tocList.innerHTML = sections.map(section => `
                <li><a href="#${section.id}">${section.title}</a></li>
            `).join('');
        }

        // Génération du contenu du rapport
        function generateReportContent() {
            const contentContainer = document.getElementById('report-content');
            
            contentContainer.innerHTML = `
                <section id="system-info" class="section">
                    <h2>🖥️ Informations Système</h2>
                    ${generateSystemInfo()}
                </section>
                
                <section id="database-overview" class="section">
                    <h2>🗃️ Aperçu des Bases de Données</h2>
                    ${generateDatabaseOverview()}
                </section>
                
                <section id="table-statistics" class="section">
                    <h2>📊 Statistiques des Tables</h2>
                    ${generateTableStatistics()}
                </section>
                
                <section id="index-performance" class="section">
                    <h2>⚡ Performance des Index</h2>
                    ${generateIndexPerformance()}
                </section>
                
                <section id="active-connections" class="section">
                    <h2>🔗 Connexions Actives</h2>
                    ${generateActiveConnections()}
                </section>
                
                <section id="locks-monitoring" class="section">
                    <h2>🔒 Surveillance des Verrous</h2>
                    ${generateLocksMonitoring()}
                </section>
                
                <section id="server-config" class="section">
                    <h2>⚙️ Configuration du Serveur</h2>
                    ${generateServerConfig()}
                </section>
                
                <section id="replication-status" class="section">
                    <h2>🔄 État de la Réplication</h2>
                    ${generateReplicationStatus()}
                </section>
                
                <section id="storage-analysis" class="section">
                    <h2>💾 Analyse du Stockage</h2>
                    ${generateStorageAnalysis()}
                </section>
                
                <section id="wal-statistics" class="section">
                    <h2>📝 Statistiques WAL</h2>
                    ${generateWALStatistics()}
                </section>
            `;
        }

        // Fonctions de génération pour chaque section
        function generateSystemInfo() {
            const data = parseCSV(reportData.system_info || 'database,version\nERROR');
            if (data[0] && data[0].database === 'ERROR') {
                return '<p class="warning">Données non disponibles</p>';
            }
            
            return `
                <div class="stats-grid">
                    ${data.map(row => `
                        <div class="stat-item">
                            <strong>${row.parametre}</strong><br>
                            <span>${row.valeur} ${row.unite || ''}</span>
                        </div>
                    `).join('')}
                </div>
            `;
        }

        function generateDatabaseOverview() {
            const data = parseCSV(reportData.database_info || 'database,ERROR');
            if (data[0] && data[0].database === 'ERROR') {
                return '<p class="warning">Données non disponibles</p>';
            }
            
            return `
                <table>
                    <thead>
                        <tr>
                            <th>Base de données</th>
                            <th>Propriétaire</th>
                            <th>Taille</th>
                            <th>Encodage</th>
                            <th>Connexions autorisées</th>
                            <th>Âge XID</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${data.map(db => `
                            <tr>
                                <td>${db.database}</td>
                                <td>${db.proprietaire}</td>
                                <td>${db.taille}</td>
                                <td>${db.encodage}</td>
                                <td>${db.connexion_autorisee === 't' ? '✅ Oui' : '❌ Non'}</td>
                                <td>${db.age_xid}</td>
                            </tr>
                        `).join('')}
                    </tbody>
                </table>
            `;
        }

        function generateTableStatistics() {
            const data = parseCSV(reportData.table_statistics || 'table,ERROR');
            if (data[0] && data[0].table === 'ERROR') {
                return '<p class="warning">Données non disponibles</p>';
            }
            
            return `
                <table>
                    <thead>
                        <tr>
                            <th>Schéma</th>
                            <th>Table</th>
                            <th>Lignes</th>
                            <th>Lignes mortes</th>
                            <th>% Mort</th>
                            <th>Dernier VACUUM</th>
                            <th>Dernier ANALYZE</th>
                            <th>Taille</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${data.map(table => {
                            const deadPercent = parseFloat(table.pourcentage_mort) || 0;
                            const rowClass = deadPercent > 50 ? 'critical-row' : deadPercent > 20 ? 'warning-row' : '';
                            return `
                                <tr class="${rowClass}">
                                    <td>${table.schema}</td>
                                    <td>${table.table}</td>
                                    <td>${table.lignes}</td>
                                    <td>${table.lignes_mortes}</td>
                                    <td>${table.pourcentage_mort}%</td>
                                    <td>${table.dernier_vacuum || 'N/A'}</td>
                                    <td>${table.dernier_analyze || 'N/A'}</td>
                                    <td>${table.taille}</td>
                                </tr>
                            `;
                        }).join('')}
                    </tbody>
                </table>
                <div class="stat-item ${data.some(t => parseFloat(t.pourcentage_mort) > 20) ? 'warning' : 'success'}">
                    <strong>Recommandation:</strong> ${data.some(t => parseFloat(t.pourcentage_mort) > 50) 
                        ? '⚠️ Certaines tables ont un pourcentage de lignes mortes élevé. Un VACUUM est recommandé.' 
                        : '✅ État des tables satisfaisant.'}
                </div>
            `;
        }

        function generateIndexPerformance() {
            const data = parseCSV(reportData.index_info || 'index,ERROR');
            if (data[0] && data[0].index === 'ERROR') {
                return '<p class="warning">Données non disponibles</p>';
            }
            
            return `
                <table>
                    <thead>
                        <tr>
                            <th>Schéma</th>
                            <th>Table</th>
                            <th>Index</th>
                            <th>Scans</th>
                            <th>Tuples lus</th>
                            <th>Tuples récupérés</th>
                            <th>Taille</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${data.map(index => `
                            <tr>
                                <td>${index.schema}</td>
                                <td>${index.table}</td>
                                <td>${index.index}</td>
                                <td>${index.scans}</td>
                                <td>${index.tuples_lus}</td>
                                <td>${index.tuples_recuperes}</td>
                                <td>${index.taille_index}</td>
                            </tr>
                        `).join('')}
                    </tbody>
                </table>
            `;
        }

        function generateActiveConnections() {
            const data = parseCSV(reportData.active_connections || 'database,ERROR');
            if (data[0] && data[0].database === 'ERROR') {
                return '<p class="warning">Données non disponibles</p>';
            }
            
            return `
                <table>
                    <thead>
                        <tr>
                            <th>Base de données</th>
                            <th>Utilisateur</th>
                            <th>Application</th>
                            <th>Adresse client</th>
                            <th>État</th>
                            <th>Début requête</th>
                            <th>Requête</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${data.map(conn => `
                            <tr>
                                <td>${conn.database}</td>
                                <td>${conn.utilisateur}</td>
                                <td>${conn.application}</td>
                                <td>${conn.adresse_client}</td>
                                <td>${conn.etat}</td>
                                <td>${conn.debut_requete}</td>
                                <td title="${conn.requete}">${conn.requete ? conn.requete.substring(0, 50) + '...' : ''}</td>
                            </tr>
                        `).join('')}
                    </tbody>
                </table>
            `;
        }

        // Les autres fonctions de génération suivent le même modèle...
        // [Les fonctions restantes sont similaires - elles génèrent le HTML pour chaque section]

        function generateLocksMonitoring() {
            const data = parseCSV(reportData.active_locks || 'database,ERROR');
            if (data[0] && data[0].database === 'ERROR') {
                return '<p class="warning">Données non disponibles</p>';
            }
            
            if (data.length === 0) {
                return '<p>Aucun verrou actif détecté.</p>';
            }
            
            return `
                <table>
                    <thead>
                        <tr>
                            <th>Base de données</th>
                            <th>Relation</th>
                            <th>Type de verrou</th>
                            <th>Accordé</th>
                            <th>Utilisateur</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${data.map(lock => `
                            <tr>
                                <td>${lock.database}</td>
                                <td>${lock.relation}</td>
                                <td>${lock.type_verrou}</td>
                                <td>${lock.accorde === 't' ? '✅ Oui' : '❌ Non'}</td>
                                <td>${lock.utilisateur}</td>
                            </tr>
                        `).join('')}
                    </tbody>
                </table>
            `;
        }

        function generateServerConfig() {
            const data = parseCSV(reportData.server_config || 'parametre,ERROR');
            if (data[0] && data[0].parametre === 'ERROR') {
                return '<p class="warning">Données non disponibles</p>';
            }
            
            return `
                <table>
                    <thead>
                        <tr>
                            <th>Paramètre</th>
                            <th>Valeur actuelle</th>
                            <th>Contexte</th>
                            <th>Redémarrage requis</th>
                            <th>Description</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${data.map(config => `
                            <tr>
                                <td><strong>${config.parametre}</strong></td>
                                <td>${config.valeur_actuelle} ${config.unite || ''}</td>
                                <td>${config.contexte}</td>
                                <td>${config.redemarrage_requis === 't' ? '⚠️ Oui' : '✅ Non'}</td>
                                <td title="${config.description}">${config.description ? config.description.substring(0, 80) + '...' : ''}</td>
                            </tr>
                        `).join('')}
                    </tbody>
                </table>
            `;
        }

        function generateReplicationStatus() {
            const data = parseCSV(reportData.replication_info || 'application_name,ERROR');
            if (data[0] && data[0].application_name === 'ERROR') {
                return '<p class="warning">Données non disponibles</p>';
            }
            
            if (data.length === 0) {
                return '<p>La réplication n\'est pas configurée ou aucune réplication active.</p>';
            }
            
            return `
                <table>
                    <thead>
                        <tr>
                            <th>Application</th>
                            <th>Client</th>
                            <th>État</th>
                            <th>Mode sync</th>
                            <th>Retard écriture</th>
                            <th>Retard replay</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${data.map(repl => `
                            <tr>
                                <td>${repl.application_name}</td>
                                <td>${repl.client_addr}</td>
                                <td>${repl.state}</td>
                                <td>${repl.sync_state}</td>
                                <td>${repl.write_lag || 'N/A'}</td>
                                <td>${repl.replay_lag || 'N/A'}</td>
                            </tr>
                        `).join('')}
                    </tbody>
                </table>
            `;
        }

        function generateStorageAnalysis() {
            const data = parseCSV(reportData.database_sizes || 'database,ERROR');
            if (data[0] && data[0].database === 'ERROR') {
                return '<p class="warning">Données non disponibles</p>';
            }
            
            return `
                <table>
                    <thead>
                        <tr>
                            <th>Base de données</th>
                            <th>Taille totale</th>
                            <th>Taille données</th>
                            <th>Taille système</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${data.map(db => `
                            <tr>
                                <td>${db.database}</td>
                                <td><strong>${db.taille_totale}</strong></td>
                                <td>${db.taille_donnees}</td>
                                <td>${db.taille_systeme}</td>
                            </tr>
                        `).join('')}
                    </tbody>
                </table>
            `;
        }

        function generateWALStatistics() {
            const data = parseCSV(reportData.wal_info || 'checkpoints_timed,ERROR');
            if (data[0] && data[0].checkpoints_timed === 'ERROR') {
                return '<p class="warning">Données non disponibles</p>';
            }
            
            if (data.length === 0) {
                return '<p>Aucune statistique WAL disponible.</p>';
            }
            
            const stats = data[0];
            return `
                <div class="stats-grid">
                    <div class="stat-item">
                        <strong>Checkpoints planifiés</strong><br>
                        <span>${stats.checkpoints_timed}</span>
                    </div>
                    <div class="stat-item">
                        <strong>Checkpoints demandés</strong><br>
                        <span>${stats.checkpoints_req}</span>
                    </div>
                    <div class="stat-item">
                        <strong>Temps écriture checkpoint</strong><br>
                        <span>${stats.temps_ecriture_checkpoint || 'N/A'}</span>
                    </div>
                    <div class="stat-item">
                        <strong>Buffers checkpoint</strong><br>
                        <span>${stats.buffers_checkpoint}</span>
                    </div>
                </div>
            `;
        }

        // Initialisation
        document.addEventListener('DOMContentLoaded', function() {
            document.getElementById('generation-date').textContent = new Date().toLocaleString('fr-FR');
            generateSummaryCards();
            generateTableOfContents();
            generateReportContent();
        });
    </script>
</body>
</html>
EOF

    log_info "Rapport HTML généré: $HTML_FILE"
}

# Fonction principale
main() {
    log_info "Début de l'audit PostgreSQL"
    
    check_prerequisites
    create_directories
    collect_audit_data
    generate_html_report
    
    log_info "Audit terminé avec succès!"
    log_info "Rapport disponible: file://$(realpath "$HTML_FILE")"
    
    # Ouverture automatique du rapport dans le navigateur par défaut (optionnel)
    if command -v xdg-open &> /dev/null; then
        xdg-open "$HTML_FILE" 2>/dev/null &
    elif command -v open &> /dev/null; then
        open "$HTML_FILE" 2>/dev/null &
    fi
}

# Capture des signaux pour un nettoyage propre
trap 'log_error "Audit interrompu"; exit 1' INT TERM

# Point d'entrée
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi