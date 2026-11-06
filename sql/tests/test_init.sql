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

\echo '== Test 6 : les tables audit et bronze existent, appartiennent à etl_writer et sont documentées'
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'audit.execution', 'audit.rejet', 'audit.controle_qualite',
        'bronze.agence_bio_operateur', 'bronze.laposte_code_postal',
        'bronze.insee_cog_commune', 'bronze.insee_cog_departement', 'bronze.insee_cog_region',
        'bronze.insee_population_departement', 'bronze.agreste_ra2020', 'bronze.sirene_etablissement'
    ] LOOP
        IF to_regclass(t) IS NULL THEN
            RAISE EXCEPTION 'Table % absente', t;
        END IF;
        IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = to_regclass(t)) <> 'etl_writer' THEN
            RAISE EXCEPTION 'Table % : le propriétaire doit être etl_writer', t;
        END IF;
        IF obj_description(to_regclass(t), 'pg_class') IS NULL THEN
            RAISE EXCEPTION 'Table % sans commentaire', t;
        END IF;
    END LOOP;
END $$;

\echo '== Test 7 : chaque table bronze a les 6 colonnes techniques, et ses colonnes de source sont en text'
DO $$
DECLARE t text; c text;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'bronze' LOOP
        FOREACH c IN ARRAY ARRAY['_execution_id', '_date_copie', '_fichier_source',
                                 '_numero_ligne', '_hash_ligne', '_date_chargement'] LOOP
            IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                           WHERE table_schema = 'bronze' AND table_name = t
                             AND column_name = c AND is_nullable = 'NO') THEN
                RAISE EXCEPTION 'bronze.% : colonne technique % absente ou facultative', t, c;
            END IF;
        END LOOP;
        IF EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'bronze' AND table_name = t
                     AND column_name NOT LIKE '\_%' AND data_type <> 'text') THEN
            RAISE EXCEPTION 'bronze.% : une colonne de source n''est pas en text', t;
        END IF;
    END LOOP;
END $$;

\echo '== Test 8 : droits sur les tables réelles'
DO $$
BEGIN
    IF has_table_privilege('bi_reader', 'bronze.agence_bio_operateur', 'SELECT')
       OR has_table_privilege('bi_reader', 'audit.execution', 'SELECT') THEN
        RAISE EXCEPTION 'bi_reader ne doit lire ni bronze ni audit';
    END IF;
    IF NOT has_table_privilege('qa_reader', 'bronze.agence_bio_operateur', 'SELECT') THEN
        RAISE EXCEPTION 'qa_reader doit pouvoir lire bronze';
    END IF;
    IF NOT has_table_privilege('qa_reader', 'audit.controle_qualite', 'INSERT') THEN
        RAISE EXCEPTION 'qa_reader doit pouvoir écrire ses résultats dans audit.controle_qualite';
    END IF;
    IF has_table_privilege('qa_reader', 'audit.execution', 'INSERT')
       OR has_table_privilege('qa_reader', 'audit.rejet', 'INSERT') THEN
        RAISE EXCEPTION 'qa_reader ne doit écrire ni dans audit.execution ni dans audit.rejet';
    END IF;
END $$;

\echo '== Test 9 : les contraintes de audit.execution refusent les valeurs interdites'
BEGIN;
SET ROLE etl_writer;
INSERT INTO audit.execution (job_nom, couche) VALUES ('test_ci', 'bronze');  -- valeurs par défaut : EN_COURS, now()
DO $$
BEGIN
    BEGIN
        INSERT INTO audit.execution (job_nom, couche, statut) VALUES ('test_ci', 'bronze', 'TERMINE');
        RAISE EXCEPTION 'Un statut inconnu aurait dû être refusé';
    EXCEPTION WHEN check_violation THEN NULL;  -- refus attendu
    END;
    BEGIN
        INSERT INTO audit.execution (job_nom, couche, statut) VALUES ('test_ci', 'bronze', 'SUCCES');
        RAISE EXCEPTION 'Un job terminé sans date de fin aurait dû être refusé';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO bronze.agence_bio_operateur (numero_bio, _execution_id, _date_copie, _fichier_source, _numero_ligne, _hash_ligne)
        VALUES ('1', -1, current_date, 'test.csv', 1, md5('test'));
        RAISE EXCEPTION 'Une ligne bronze liée à une exécution inexistante aurait dû être refusée';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
END $$;
ROLLBACK;

\echo '== Tous les tests sont passés'
