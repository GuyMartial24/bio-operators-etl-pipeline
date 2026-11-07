#!/bin/bash
# Base de métadonnées d'Airflow : DAG, état des tâches, historique des exécutions.
# Séparée des données du projet : le rôle airflow n'a aucun droit sur la base bio_observatoire
# (03_privileges.sql en retire la connexion à PUBLIC).
# Exécuté automatiquement à la création de la base, comme 01_roles.sh.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v airflow_pw="$AIRFLOW_DB_PASSWORD" <<'EOSQL'

CREATE ROLE airflow LOGIN PASSWORD :'airflow_pw';
COMMENT ON ROLE airflow IS 'Airflow : propriétaire de sa base de métadonnées, aucun accès aux données du projet';

CREATE DATABASE airflow OWNER airflow;
REVOKE ALL ON DATABASE airflow FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE airflow TO airflow;

EOSQL
