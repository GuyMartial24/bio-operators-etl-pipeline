-- Fusion de l'annuaire dans silver, appelée par le job Talend silver_annuaire.
-- Point de départ : silver.annuaire_prepare, remplie par Talend avec les lignes nettoyées d'une copie.
-- Ordre d'appel : verifier_ordre_copie → tracer_rejets_annuaire → ajouter_certificateurs
--                 → fusionner_operateurs → historiser_certifications.
-- Toutes les procédures s'exécutent dans la transaction du job : un échec annule tout.
-- Règles : docs/modele_donnees.md, § 3.3.

SET ROLE etl_writer;

-- 1. Les certifications de la copie : une ligne par numéro bio et par organisme.
-- Les doublons de l'annuaire sont fusionnés : union des activités, date d'engagement la plus ancienne.
CREATE VIEW silver.certification_copie AS
WITH lignes AS (
    SELECT p.numero_bio, c.certificateur_id, p.date_engagement, p.date_engagement_statut,
           p.activites, p._numero_ligne
    FROM silver.annuaire_prepare p
    JOIN silver.ref_certificateur c ON c.certificateur_libelle = p.certificateur_libelle
),
activites AS (
    SELECT l.numero_bio, l.certificateur_id,
           string_agg(DISTINCT a.activite_code, ',' ORDER BY a.activite_code) AS activites_liste
    FROM lignes l
    CROSS JOIN LATERAL unnest(string_to_array(l.activites, ',')) AS x(libelle)
    JOIN silver.ref_activite a ON a.activite_libelle = trim(x.libelle)
    GROUP BY l.numero_bio, l.certificateur_id
),
certifications AS (
    SELECT numero_bio, certificateur_id,
           min(date_engagement) AS date_engagement,
           CASE WHEN min(date_engagement) IS NOT NULL THEN 'VALIDE'
                WHEN bool_or(date_engagement_statut = 'FUTURE') THEN 'FUTURE'
                ELSE 'ABSENTE' END AS date_engagement_statut,
           count(*) AS nb_lignes_source
    FROM lignes
    GROUP BY numero_bio, certificateur_id
)
SELECT c.numero_bio, c.certificateur_id, c.date_engagement, c.date_engagement_statut,
       coalesce(a.activites_liste, '') AS activites_liste,
       md5(concat_ws(';', coalesce(c.date_engagement::text, ''), coalesce(a.activites_liste, ''))) AS hash_attributs,
       c.nb_lignes_source
FROM certifications c
LEFT JOIN activites a USING (numero_bio, certificateur_id);

COMMENT ON VIEW silver.certification_copie IS
    'Certifications de la copie en cours (silver.annuaire_prepare), doublons fusionnés, avec leur empreinte';

-- 2. Les copies se traitent dans l'ordre chronologique.
-- Traiter une copie plus ancienne que la dernière historisée fausserait les intervalles de la SCD 2.
CREATE PROCEDURE silver.verifier_ordre_copie(p_date_copie date)
LANGUAGE plpgsql AS $$
DECLARE
    v_derniere date;
BEGIN
    SELECT max(greatest(date_debut, coalesce(date_fin, date_debut))) INTO v_derniere FROM silver.certification;
    IF v_derniere > p_date_copie THEN
        RAISE EXCEPTION 'Copie du % plus ancienne que la dernière copie historisée (%)', p_date_copie, v_derniere;
    END IF;
END $$;

-- 3. Rejets et anomalies, tracés depuis bronze avec la ligne source complète en JSON.
CREATE PROCEDURE silver.tracer_rejets_annuaire(p_date_copie date, p_execution_id bigint)
LANGUAGE sql AS $$
    -- Ligne écartée par Talend : numéro bio absent ou non numérique
    INSERT INTO audit.rejet (execution_id, table_source, hash_ligne_source, table_cible, motif_code, motif_detail, ligne_source)
    SELECT p_execution_id, 'bronze.agence_bio_operateur', b._hash_ligne, 'silver.operateur',
           'NUMERO_BIO_ABSENT', 'numero_bio : ' || coalesce(b.numero_bio, 'NULL'), to_jsonb(b)
    FROM bronze.agence_bio_operateur b
    WHERE b._date_copie = p_date_copie
      AND (b.numero_bio IS NULL OR trim(b.numero_bio) !~ '^[0-9]+$');

    -- Doublon numéro bio + organisme : gardé, mais fusionné (voir la vue certification_copie)
    INSERT INTO audit.rejet (execution_id, table_source, hash_ligne_source, table_cible, motif_code, motif_detail, ligne_source)
    SELECT p_execution_id, 'bronze.agence_bio_operateur', b._hash_ligne, 'silver.certification',
           'DOUBLON_FUSIONNE', d.nb || ' lignes pour le numéro bio ' || d.numero_bio, to_jsonb(b)
    FROM (SELECT _numero_ligne, numero_bio,
                 count(*) OVER (PARTITION BY numero_bio, certificateur_libelle) AS nb
          FROM silver.annuaire_prepare) d
    JOIN bronze.agence_bio_operateur b ON b._date_copie = p_date_copie AND b._numero_ligne = d._numero_ligne
    WHERE d.nb > 1;

    -- Activité absente du référentiel : la ligne est gardée, l'activité est ignorée
    INSERT INTO audit.rejet (execution_id, table_source, hash_ligne_source, table_cible, motif_code, motif_detail, ligne_source)
    SELECT p_execution_id, 'bronze.agence_bio_operateur', b._hash_ligne, 'silver.certification_activite',
           'ACTIVITE_INCONNUE', 'activité : ' || trim(x.libelle), to_jsonb(b)
    FROM silver.annuaire_prepare p
    CROSS JOIN LATERAL unnest(string_to_array(p.activites, ',')) AS x(libelle)
    JOIN bronze.agence_bio_operateur b ON b._date_copie = p_date_copie AND b._numero_ligne = p._numero_ligne
    WHERE NOT EXISTS (SELECT 1 FROM silver.ref_activite a WHERE a.activite_libelle = trim(x.libelle));
$$;

-- 4. Organismes certificateurs : ajout des nouveaux
CREATE PROCEDURE silver.ajouter_certificateurs(p_date_copie date)
LANGUAGE sql AS $$
    INSERT INTO silver.ref_certificateur (certificateur_libelle, est_dispense, date_premiere_observation)
    SELECT DISTINCT certificateur_libelle, certificateur_libelle = 'Dispense de certification', p_date_copie
    FROM silver.annuaire_prepare
    ON CONFLICT (certificateur_libelle) DO NOTHING;
$$;

-- 5. Opérateurs, état courant (SCD 1)
CREATE PROCEDURE silver.fusionner_operateurs(p_date_copie date)
LANGUAGE sql AS $$
    -- Un opérateur à plusieurs organismes a plusieurs lignes : on garde la première.
    INSERT INTO silver.operateur (numero_bio, siret, siret_statut, denomination, code_postal, code_postal_statut,
                                  code_departement, methode_rattachement, est_present,
                                  date_premiere_observation, date_derniere_observation)
    SELECT DISTINCT ON (numero_bio)
           numero_bio, siret, siret_statut, denomination, code_postal, code_postal_statut,
           code_departement, methode_rattachement, true, p_date_copie, p_date_copie
    FROM silver.annuaire_prepare
    ORDER BY numero_bio, _numero_ligne
    ON CONFLICT (numero_bio) DO UPDATE SET
        siret                     = EXCLUDED.siret,
        siret_statut              = EXCLUDED.siret_statut,
        denomination              = EXCLUDED.denomination,
        code_postal               = EXCLUDED.code_postal,
        code_postal_statut        = EXCLUDED.code_postal_statut,
        code_departement          = EXCLUDED.code_departement,
        methode_rattachement      = EXCLUDED.methode_rattachement,
        est_present               = true,
        date_derniere_observation = EXCLUDED.date_derniere_observation;
        -- date_premiere_observation n'est jamais modifiée

    -- Absents de la copie : gardés, mais marqués
    UPDATE silver.operateur o
    SET est_present = false
    WHERE o.est_present
      AND NOT EXISTS (SELECT 1 FROM silver.annuaire_prepare p WHERE p.numero_bio = o.numero_bio);
$$;

-- 6. Certifications, historique (SCD 2)
CREATE PROCEDURE silver.historiser_certifications(p_date_copie date, p_execution_id bigint)
LANGUAGE sql AS $$
    -- a. Fermer les versions courantes modifiées ou disparues
    UPDATE silver.certification v
    SET date_fin = p_date_copie, est_courant = false
    WHERE v.est_courant
      AND NOT EXISTS (SELECT 1 FROM silver.certification_copie c
                      WHERE c.numero_bio = v.numero_bio
                        AND c.certificateur_id = v.certificateur_id
                        AND c.hash_attributs = v.hash_attributs);

    -- b. Ouvrir une version pour chaque certification sans version courante (nouvelle ou modifiée)
    INSERT INTO silver.certification (numero_bio, certificateur_id, date_engagement, date_engagement_statut,
                                      activites_liste, hash_attributs, date_debut, est_courant,
                                      est_chargement_initial, _execution_id)
    SELECT c.numero_bio, c.certificateur_id, c.date_engagement, c.date_engagement_statut,
           c.activites_liste, c.hash_attributs, p_date_copie, true,
           NOT EXISTS (SELECT 1 FROM silver.certification),   -- table vide : premier chargement
           p_execution_id
    FROM silver.certification_copie c
    WHERE NOT EXISTS (SELECT 1 FROM silver.certification v
                      WHERE v.est_courant
                        AND v.numero_bio = c.numero_bio
                        AND v.certificateur_id = c.certificateur_id);

    -- c. Les activités des versions ouvertes par cette exécution
    INSERT INTO silver.certification_activite (certification_version_id, activite_code)
    SELECT v.certification_version_id, a.activite_code
    FROM silver.certification v
    CROSS JOIN LATERAL unnest(string_to_array(v.activites_liste, ',')) AS a(activite_code)
    WHERE v._execution_id = p_execution_id;
$$;

RESET ROLE;
