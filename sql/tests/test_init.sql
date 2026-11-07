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

\echo '== Test 3 bis : airflow n''a accès qu''à sa propre base'
DO $$
BEGIN
    IF has_database_privilege('airflow', current_database(), 'CONNECT') THEN
        RAISE EXCEPTION 'airflow ne doit pas pouvoir se connecter à la base des données';
    END IF;
    IF NOT has_database_privilege('airflow', 'airflow', 'CONNECT') THEN
        RAISE EXCEPTION 'airflow doit pouvoir se connecter à sa base de métadonnées';
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

\echo '== Test 6 : les tables audit, bronze et silver existent, appartiennent à etl_writer et sont documentées'
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'audit.execution', 'audit.rejet', 'audit.controle_qualite',
        'bronze.agence_bio_operateur', 'bronze.insee_cog_departement', 'bronze.insee_cog_region',
        'bronze.insee_population_departement',
        'silver.ref_region', 'silver.ref_departement', 'silver.population_departement',
        'silver.ref_activite', 'silver.ref_certificateur', 'silver.operateur',
        'silver.certification', 'silver.certification_activite', 'silver.annuaire_prepare',
        'gold.dim_date', 'gold.dim_departement', 'gold.dim_activite', 'gold.dim_certificateur',
        'gold.fait_certification_activite'
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
       OR has_table_privilege('bi_reader', 'audit.execution', 'SELECT')
       OR has_table_privilege('bi_reader', 'silver.operateur', 'SELECT') THEN
        RAISE EXCEPTION 'bi_reader ne doit lire ni bronze, ni silver (données personnelles), ni audit';
    END IF;
    IF NOT has_table_privilege('qa_reader', 'silver.operateur', 'SELECT')
       OR has_table_privilege('qa_reader', 'silver.operateur', 'INSERT') THEN
        RAISE EXCEPTION 'qa_reader doit lire silver sans pouvoir y écrire';
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

\echo '== Test 10 : les contraintes de silver refusent les incohérences'
-- On insère un jeu minimal valide, on tente des lignes interdites, puis on annule tout.
-- ON CONFLICT DO NOTHING et numero_bio = -1 : le test fonctionne aussi sur une base déjà remplie.
BEGIN;
SET ROLE etl_writer;
INSERT INTO audit.execution (job_nom, couche) VALUES ('test_ci', 'silver');
INSERT INTO silver.ref_region VALUES ('84', 'Auvergne-Rhône-Alpes', 2026) ON CONFLICT DO NOTHING;
INSERT INTO silver.ref_departement VALUES ('01', 'Ain', '84', false, 2026), ('00', 'Inconnu', NULL, false, 2026)
    ON CONFLICT DO NOTHING;
INSERT INTO silver.ref_certificateur (certificateur_libelle, est_dispense, date_premiere_observation)
    VALUES ('Organisme test CI', false, '2026-11-05');
INSERT INTO silver.operateur (numero_bio, siret_statut, denomination, code_postal, code_postal_statut,
                              code_departement, methode_rattachement, est_present,
                              date_premiere_observation, date_derniere_observation)
    VALUES (-1, 'ABSENT', 'Test', '01000', 'VALIDE', '01', 'CODE_POSTAL', true, '2026-11-05', '2026-11-05');
INSERT INTO silver.certification (numero_bio, certificateur_id, date_engagement_statut, activites_liste,
                                  hash_attributs, date_debut, est_courant, est_chargement_initial, _execution_id)
    SELECT -1, max(certificateur_id), 'ABSENTE', 'PRODUCTION', md5('x'), '2026-11-05', true, true, max(e.execution_id)
    FROM silver.ref_certificateur, audit.execution e;
DO $$
BEGIN
    BEGIN
        INSERT INTO silver.certification (numero_bio, certificateur_id, date_engagement_statut, activites_liste,
                                          hash_attributs, date_debut, est_courant, est_chargement_initial, _execution_id)
            SELECT numero_bio, certificateur_id, 'ABSENTE', 'PREPARATION', md5('y'), '2026-11-06', true, false, _execution_id
            FROM silver.certification WHERE numero_bio = -1;
        RAISE EXCEPTION 'Deux versions courantes pour la même certification auraient dû être refusées';
    EXCEPTION WHEN unique_violation THEN NULL;  -- refus attendu
    END;
    BEGIN
        UPDATE silver.certification SET date_fin = '2026-11-06' WHERE numero_bio = -1;  -- fermée mais encore marquée courante
        RAISE EXCEPTION 'Une version fermée marquée courante aurait dû être refusée';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE silver.operateur SET siret = '12345678901234' WHERE numero_bio = -1;  -- SIRET présent avec le statut ABSENT
        RAISE EXCEPTION 'Un SIRET incohérent avec son statut aurait dû être refusé';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE silver.operateur SET code_departement = '00' WHERE numero_bio = -1;  -- département inconnu avec la méthode CODE_POSTAL
        RAISE EXCEPTION 'Un rattachement incohérent aurait dû être refusé';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO silver.ref_departement VALUES ('99', 'Étranger', '84', false, 2026);
        RAISE EXCEPTION 'Un membre spécial rattaché à une région aurait dû être refusé';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END $$;
ROLLBACK;

\echo '== Test 11 : la fusion de l''annuaire historise les certifications (SCD 2)'
-- Deux copies fictives (2099) d'un opérateur fictif (-2), puis tout est annulé.
BEGIN;
SET ROLE etl_writer;
DELETE FROM silver.annuaire_prepare;
INSERT INTO silver.ref_region VALUES ('84', 'Auvergne-Rhône-Alpes', 2026) ON CONFLICT DO NOTHING;
INSERT INTO silver.ref_departement VALUES ('01', 'Ain', '84', false, 2026) ON CONFLICT DO NOTHING;
INSERT INTO silver.ref_activite VALUES ('PRODUCTION', 'Production', 'production'),
                                       ('TRANSPORT', 'Transport', 'logistique') ON CONFLICT DO NOTHING;
INSERT INTO audit.execution (job_nom, couche, date_copie) VALUES ('test_ci', 'silver', '2099-01-01');
INSERT INTO silver.annuaire_prepare
    VALUES (-2, NULL, 'ABSENT', 'Test', '01000', 'VALIDE', '01', 'CODE_POSTAL', '2020-01-01', 'VALIDE',
            'Production', 'Organisme test CI', 1, currval('audit.execution_execution_id_seq'));
CALL silver.verifier_ordre_copie('2099-01-01');
CALL silver.ajouter_certificateurs('2099-01-01');
CALL silver.fusionner_operateurs('2099-01-01');
CALL silver.historiser_certifications('2099-01-01', currval('audit.execution_execution_id_seq'));
-- Copie suivante : une activité de plus
INSERT INTO audit.execution (job_nom, couche, date_copie) VALUES ('test_ci', 'silver', '2099-01-02');
UPDATE silver.annuaire_prepare SET activites = 'Production,Transport';
CALL silver.verifier_ordre_copie('2099-01-02');
CALL silver.fusionner_operateurs('2099-01-02');
CALL silver.historiser_certifications('2099-01-02', currval('audit.execution_execution_id_seq'));
DO $$
BEGIN
    IF (SELECT count(*) FROM silver.certification WHERE numero_bio = -2) <> 2 THEN
        RAISE EXCEPTION 'Un changement d''activités doit créer une seconde version';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM silver.certification
                   WHERE numero_bio = -2 AND date_fin = '2099-01-02' AND NOT est_courant) THEN
        RAISE EXCEPTION 'L''ancienne version doit être fermée à la date de la copie suivante';
    END IF;
    IF (SELECT activites_liste FROM silver.certification WHERE numero_bio = -2 AND est_courant)
       <> 'PRODUCTION,TRANSPORT' THEN
        RAISE EXCEPTION 'La version courante doit porter la nouvelle liste d''activités';
    END IF;
    IF (SELECT count(*) FROM silver.certification_activite a
        JOIN silver.certification v USING (certification_version_id)
        WHERE v.numero_bio = -2 AND v.est_courant) <> 2 THEN
        RAISE EXCEPTION 'La version courante doit avoir ses 2 activités';
    END IF;
    IF (SELECT date_derniere_observation FROM silver.operateur WHERE numero_bio = -2) <> '2099-01-02' THEN
        RAISE EXCEPTION 'L''opérateur doit être mis à jour (SCD 1)';
    END IF;
    BEGIN
        CALL silver.verifier_ordre_copie('2099-01-01');
        RAISE EXCEPTION 'Une copie plus ancienne que la dernière historisée aurait dû être refusée';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'Copie du %' THEN RAISE; END IF;  -- seul le refus attendu est accepté
    END;
END $$;
ROLLBACK;

\echo '== Test 12 : gold ne contient aucune donnée personnelle et se reconstruit'
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'gold' AND column_name IN ('denomination', 'siret', 'numero_bio')) THEN
        RAISE EXCEPTION 'gold ne doit contenir ni nom, ni SIRET, ni numéro bio';
    END IF;
    IF NOT has_table_privilege('bi_reader', 'gold.fait_certification_activite', 'SELECT')
       OR NOT has_table_privilege('bi_reader', 'gold.dim_departement', 'SELECT') THEN
        RAISE EXCEPTION 'bi_reader doit pouvoir lire l''étoile';
    END IF;
END $$;
BEGIN;
SET ROLE etl_writer;
CALL gold.reconstruire_etoile();
DO $$
BEGIN
    IF (SELECT count(*) FROM gold.dim_date WHERE date_id = -1) <> 1
       OR (SELECT count(*) FROM gold.dim_departement WHERE departement_id = -1) <> 1
       OR (SELECT count(*) FROM gold.dim_activite WHERE activite_id = -1) <> 1
       OR (SELECT count(*) FROM gold.dim_certificateur WHERE certificateur_id = -1) <> 1 THEN
        RAISE EXCEPTION 'Chaque dimension doit avoir son membre -1';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM gold.dim_date WHERE date = '1994-01-01')
       OR (SELECT mois_libelle FROM gold.dim_date WHERE date_id = 20260815) <> 'août' THEN
        RAISE EXCEPTION 'Le calendrier doit commencer en 1994 et nommer les mois en français';
    END IF;
END $$;
ROLLBACK;

\echo '== Tous les tests sont passés'
