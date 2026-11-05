#!/bin/bash
# Crée les rôles applicatifs (principe du moindre privilège).
# Exécuté automatiquement par l'image PostgreSQL, une seule fois : à la création de la base.
# C'est un script shell (et pas du SQL) pour lire les mots de passe depuis les variables d'environnement.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v etl_pw="$ETL_WRITER_PASSWORD" \
     -v bi_pw="$BI_READER_PASSWORD" \
     -v qa_pw="$QA_READER_PASSWORD" <<'EOSQL'

CREATE ROLE etl_writer LOGIN PASSWORD :'etl_pw';
CREATE ROLE bi_reader  LOGIN PASSWORD :'bi_pw';
CREATE ROLE qa_reader  LOGIN PASSWORD :'qa_pw';

COMMENT ON ROLE etl_writer IS 'Talend : propriétaire des schémas, crée et alimente les tables';
COMMENT ON ROLE bi_reader  IS 'Power BI : lecture seule sur gold';
COMMENT ON ROLE qa_reader  IS 'Notebooks de contrôle : lecture sur toutes les couches, écriture dans audit';

EOSQL
