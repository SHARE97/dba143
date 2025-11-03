#!/bin/bash

# Configuration de l'audit PostgreSQL

# Définir les variables d'environnement pour la connexion
export PGUSER="postgres"
export PGHOST="localhost"
export PGPORT="5432"

# Ou utiliser un fichier .pgpass
# echo "localhost:5432:*:postgres:password" > ~/.pgpass
# chmod 600 ~/.pgpass

echo "Configuration de l'audit PostgreSQL"
echo "Variables d'environnement définies:"
echo "PGUSER: $PGUSER"
echo "PGHOST: $PGHOST"
echo "PGPORT: $PGPORT"
echo ""
echo "Pour modifier, éditez ce script ou définissez les variables d'environnement"