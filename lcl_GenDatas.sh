#!/bin/bash

DB="postgres"
TABLE_NAME="charge_replication"
PGUSER="postgres"

echo "Création de la table de test..."
psql -U $PGUSER -d $DB -c "DROP TABLE IF EXISTS $TABLE_NAME;"
psql -U $PGUSER -d $DB -c "CREATE TABLE $TABLE_NAME(id SERIAL PRIMARY KEY, valeur TEXT NOT NULL);"

echo "Insertion de 2 millions de lignes..."
psql -U $PGUSER -d $DB -c "
  INSERT INTO $TABLE_NAME(valeur)
  SELECT 'ligne_' || generate_series(1,2000000);
"

echo "Comptage sur la primaire (doit afficher 2 millions) :"
psql -U $PGUSER -d $DB -c "SELECT COUNT(*) FROM $TABLE_NAME;"

echo "Vous pouvez maintenant vérifier la réplication sur le réplicat !"

