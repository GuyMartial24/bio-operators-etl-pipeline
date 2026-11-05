-- Tests de l'initialisation de la base : schémas, rôles et droits.
-- Chaque test lève une erreur (RAISE EXCEPTION) s'il échoue, ce qui arrête psql et fait échouer la CI.
-- Lancement : docker compose exec -T postgres psql -U <admin> -d <base> -v ON_ERROR_STOP=1 < sql/tests/test_init.sql

\echo '== Test 1 : les 4 schémas existent et appartiennent à etl_writer'
DO $$
DECLARE s text;
BEGIN
    FOREACH s IN ARRAY ARRAY['bronze', 'silver', 'gold', 'audit'] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_namespace
            WHERE nspname = s AND pg_get_userbyid(nspowner) = 'etl_writer'
        ) THEN
            RAISE EXCEPTION 'Schéma % absent ou mauvais propriétaire', s;
        END IF;
    END LOOP;
END $$;

\echo '== Test 2 : les 3 rôles existent et peuvent se connecter'
DO $$
DECLARE r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['etl_writer', 'bi_reader', 'qa_reader'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r AND rolcanlogin) THEN
            RAISE EXCEPTION 'Rôle % absent ou sans droit de connexion', r;
        END IF;
        IF NOT has_database_privilege(r, current_database(), 'CONNECT') THEN
            RAISE EXCEPTION 'Rôle % ne peut pas se connecter à la base', r;
        END IF;
    END LOOP;
END $$;

\echo '== Test 3 : bi_reader (Power BI) entre dans gold uniquement, sans pouvoir y créer'
DO $$
BEGIN
    IF NOT has_schema_privilege('bi_reader', 'gold', 'USAGE') THEN
        RAISE EXCEPTION 'bi_reader doit avoir USAGE sur gold';
    END IF;
    IF has_schema_privilege('bi_reader', 'gold', 'CREATE') THEN
        RAISE EXCEPTION 'bi_reader ne doit pas pouvoir créer dans gold';
    END IF;
    IF has_schema_privilege('bi_reader', 'silver', 'USAGE')
       OR has_schema_privilege('bi_reader', 'bronze', 'USAGE')
       OR has_schema_privilege('bi_reader', 'audit', 'USAGE') THEN
        RAISE EXCEPTION 'bi_reader ne doit voir que gold (données personnelles en silver)';
    END IF;
END $$;

\echo '== Test 4 : qa_reader (notebooks) entre dans les 4 schémas, sans pouvoir y créer'
DO $$
DECLARE s text;
BEGIN
    FOREACH s IN ARRAY ARRAY['bronze', 'silver', 'gold', 'audit'] LOOP
        IF NOT has_schema_privilege('qa_reader', s, 'USAGE') THEN
            RAISE EXCEPTION 'qa_reader doit avoir USAGE sur %', s;
        END IF;
        IF has_schema_privilege('qa_reader', s, 'CREATE') THEN
            RAISE EXCEPTION 'qa_reader ne doit pas pouvoir créer dans %', s;
        END IF;
    END LOOP;
END $$;

\echo '== Test 5 : les tables futures créées par etl_writer reçoivent les bons droits (DEFAULT PRIVILEGES)'
-- On crée des tables de test dans une transaction, puis on annule tout (ROLLBACK) : la base reste propre.
BEGIN;
SET ROLE etl_writer;
CREATE TABLE gold.ci_test (id int);
CREATE TABLE silver.ci_test (id int);
CREATE TABLE audit.ci_test (id int);
RESET ROLE;
DO $$
BEGIN
    IF NOT has_table_privilege('bi_reader', 'gold.ci_test', 'SELECT') THEN
        RAISE EXCEPTION 'bi_reader doit pouvoir lire les nouvelles tables de gold';
    END IF;
    IF has_table_privilege('bi_reader', 'gold.ci_test', 'INSERT') THEN
        RAISE EXCEPTION 'bi_reader ne doit pas pouvoir écrire dans gold';
    END IF;
    IF NOT has_table_privilege('qa_reader', 'silver.ci_test', 'SELECT') THEN
        RAISE EXCEPTION 'qa_reader doit pouvoir lire les nouvelles tables de silver';
    END IF;
    IF has_table_privilege('qa_reader', 'silver.ci_test', 'INSERT') THEN
        RAISE EXCEPTION 'qa_reader ne doit pas pouvoir écrire dans silver';
    END IF;
    IF NOT has_table_privilege('qa_reader', 'audit.ci_test', 'INSERT') THEN
        RAISE EXCEPTION 'qa_reader doit pouvoir écrire dans audit (résultats des contrôles)';
    END IF;
END $$;
ROLLBACK;

\echo '== Tous les tests sont passés'
