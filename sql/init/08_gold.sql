-- Schéma gold : le modèle en étoile lu par Power BI (rôle bi_reader).
-- Une table de faits et 4 dimensions, recalculées entièrement à chaque exécution du job gold_etoile
-- à partir des versions courantes de silver. Aucune donnée personnelle : ni nom, ni SIRET, ni numéro bio.
-- Chaque dimension a un membre -1 (« inconnu ») : un fait dont la dimension manque y est rattaché
-- au lieu de disparaître dans une jointure.
-- Description : docs/dictionnaire_donnees.md, docs/modele_donnees.md (§ 3.4).

SET ROLE etl_writer;

-- 1. Dimensions
CREATE TABLE gold.dim_date (
    date_id       integer  PRIMARY KEY,       -- AAAAMMJJ, -1 = inconnue
    date          date     UNIQUE,
    annee         smallint,
    trimestre     smallint CHECK (trimestre BETWEEN 1 AND 4),
    mois          smallint CHECK (mois BETWEEN 1 AND 12),
    mois_libelle  text
);
COMMENT ON TABLE  gold.dim_date IS 'Calendrier, un jour par ligne, du 1994-01-01 au 31 décembre de l''année suivante. -1 = date inconnue';
COMMENT ON COLUMN gold.dim_date.date_id      IS 'Clé AAAAMMJJ (20261105), -1 = inconnue';
COMMENT ON COLUMN gold.dim_date.date         IS 'La date';
COMMENT ON COLUMN gold.dim_date.annee        IS 'Année';
COMMENT ON COLUMN gold.dim_date.trimestre    IS 'Trimestre, 1 à 4';
COMMENT ON COLUMN gold.dim_date.mois         IS 'Mois, 1 à 12';
COMMENT ON COLUMN gold.dim_date.mois_libelle IS 'Nom du mois en français';

CREATE TABLE gold.dim_departement (
    departement_id       smallint PRIMARY KEY,
    code_departement     text     NOT NULL UNIQUE,
    departement_libelle  text     NOT NULL,
    code_region          text,
    region_libelle       text,
    est_outre_mer        boolean  NOT NULL,
    population           integer,
    annee_population     smallint
);
COMMENT ON TABLE  gold.dim_departement IS 'Départements, plus 99 étranger, 00 inconnu et -1 non renseigné';
COMMENT ON COLUMN gold.dim_departement.departement_id      IS 'Clé technique';
COMMENT ON COLUMN gold.dim_departement.code_departement    IS 'Code, joint aux contours des départements dans Power BI';
COMMENT ON COLUMN gold.dim_departement.departement_libelle IS 'Nom du département';
COMMENT ON COLUMN gold.dim_departement.code_region         IS 'Code de la région';
COMMENT ON COLUMN gold.dim_departement.region_libelle      IS 'Nom de la région';
COMMENT ON COLUMN gold.dim_departement.est_outre_mer       IS 'Département d''outre-mer';
COMMENT ON COLUMN gold.dim_departement.population          IS 'Population municipale du dernier millésime. Vide pour Mayotte';
COMMENT ON COLUMN gold.dim_departement.annee_population    IS 'Millésime de la population';

CREATE TABLE gold.dim_activite (
    activite_id       smallint PRIMARY KEY,
    activite_code     text     NOT NULL UNIQUE,
    activite_libelle  text     NOT NULL,
    famille           text     NOT NULL
);
COMMENT ON TABLE  gold.dim_activite IS 'Les 8 activités et leur famille, plus -1 inconnue';
COMMENT ON COLUMN gold.dim_activite.activite_id      IS 'Clé technique';
COMMENT ON COLUMN gold.dim_activite.activite_code    IS 'Code de l''activité (PREPARATION)';
COMMENT ON COLUMN gold.dim_activite.activite_libelle IS 'Libellé (Préparation)';
COMMENT ON COLUMN gold.dim_activite.famille          IS 'production, transformation, distribution, logistique, echanges';

CREATE TABLE gold.dim_certificateur (
    certificateur_id       integer PRIMARY KEY,
    certificateur_libelle  text    NOT NULL,
    est_dispense           boolean NOT NULL
);
COMMENT ON TABLE  gold.dim_certificateur IS 'Organismes certificateurs, plus -1 inconnu';
COMMENT ON COLUMN gold.dim_certificateur.certificateur_id      IS 'Même clé qu''en silver';
COMMENT ON COLUMN gold.dim_certificateur.certificateur_libelle IS 'Nom de l''organisme';
COMMENT ON COLUMN gold.dim_certificateur.est_dispense          IS 'Dispense de certification : à exclure des parts de marché et du HHI';

-- 2. Faits : une certification en cours × une activité
CREATE TABLE gold.fait_certification_activite (
    operateur_id           integer  NOT NULL,
    certificateur_id       integer  NOT NULL REFERENCES gold.dim_certificateur (certificateur_id),
    activite_id            smallint NOT NULL REFERENCES gold.dim_activite (activite_id),
    departement_id         smallint NOT NULL REFERENCES gold.dim_departement (departement_id),
    date_engagement_id     integer  NOT NULL REFERENCES gold.dim_date (date_id),
    nb_operateur_activite  smallint NOT NULL DEFAULT 1 CHECK (nb_operateur_activite = 1),
    PRIMARY KEY (operateur_id, certificateur_id, activite_id)
);
-- Un index par clé de dimension : Power BI filtre par département, activité, organisme ou date.
CREATE INDEX fait_certificateur_idx   ON gold.fait_certification_activite (certificateur_id);
CREATE INDEX fait_activite_idx        ON gold.fait_certification_activite (activite_id);
CREATE INDEX fait_departement_idx     ON gold.fait_certification_activite (departement_id);
CREATE INDEX fait_date_engagement_idx ON gold.fait_certification_activite (date_engagement_id);
COMMENT ON TABLE  gold.fait_certification_activite IS
    'Une ligne par certification en cours et par activité. Nombre d''opérateurs = DISTINCTCOUNT(operateur_id), jamais une somme';
COMMENT ON COLUMN gold.fait_certification_activite.operateur_id          IS 'Pseudonyme de l''opérateur (dimension dégénérée). La correspondance reste en silver';
COMMENT ON COLUMN gold.fait_certification_activite.certificateur_id      IS 'Organisme (dim_certificateur)';
COMMENT ON COLUMN gold.fait_certification_activite.activite_id           IS 'Activité (dim_activite)';
COMMENT ON COLUMN gold.fait_certification_activite.departement_id        IS 'Département de l''opérateur (dim_departement)';
COMMENT ON COLUMN gold.fait_certification_activite.date_engagement_id    IS 'Date d''engagement (dim_date), -1 si vide';
COMMENT ON COLUMN gold.fait_certification_activite.nb_operateur_activite IS 'Toujours 1';

-- 3. Faits de mouvement : entrées et sorties d'opérateurs, tirées de l'historique SCD 2 de silver
CREATE TABLE gold.fait_mouvement (
    operateur_id        integer  NOT NULL,
    date_mouvement_id   integer  NOT NULL REFERENCES gold.dim_date (date_id),
    type_mouvement      text     NOT NULL CHECK (type_mouvement IN ('ENTREE', 'SORTIE')),
    certificateur_id    integer  NOT NULL REFERENCES gold.dim_certificateur (certificateur_id),
    departement_id      smallint NOT NULL REFERENCES gold.dim_departement (departement_id),
    nb_mouvement        smallint NOT NULL DEFAULT 1 CHECK (nb_mouvement = 1),
    PRIMARY KEY (operateur_id, date_mouvement_id, type_mouvement)
);
CREATE INDEX fait_mouvement_date_idx ON gold.fait_mouvement (date_mouvement_id);
COMMENT ON TABLE  gold.fait_mouvement IS
    'Entrées et sorties d''opérateurs dans la filière, une ligne par opérateur, date et type. '
    'Le chargement initial (première copie) n''est pas une entrée';
COMMENT ON COLUMN gold.fait_mouvement.operateur_id      IS 'Pseudonyme de l''opérateur';
COMMENT ON COLUMN gold.fait_mouvement.date_mouvement_id IS 'Date de la copie où le mouvement est constaté (dim_date)';
COMMENT ON COLUMN gold.fait_mouvement.type_mouvement    IS 'ENTREE : aucune certification en cours la veille, une ce jour-là ; SORTIE : l''inverse';
COMMENT ON COLUMN gold.fait_mouvement.certificateur_id  IS 'Organisme de la certification ouverte (entrée) ou fermée (sortie)';
COMMENT ON COLUMN gold.fait_mouvement.departement_id    IS 'Département de l''opérateur (état courant)';
COMMENT ON COLUMN gold.fait_mouvement.nb_mouvement      IS 'Toujours 1';

-- 4. Reconstruction complète de l'étoile, dans la transaction du job
-- TRUNCATE verrouille les tables jusqu'au commit : Power BI attend quelques secondes,
-- puis voit la nouvelle étoile d'un coup, jamais une étoile à moitié remplie.
CREATE OR REPLACE PROCEDURE gold.reconstruire_etoile()
LANGUAGE sql AS $$
    TRUNCATE gold.fait_certification_activite, gold.fait_mouvement, gold.dim_date,
             gold.dim_departement, gold.dim_activite, gold.dim_certificateur;

    -- Calendrier
    INSERT INTO gold.dim_date VALUES (-1, NULL, NULL, NULL, NULL, 'Inconnue');
    INSERT INTO gold.dim_date (date_id, date, annee, trimestre, mois, mois_libelle)
    SELECT to_char(d, 'YYYYMMDD')::integer, d, extract(year FROM d), extract(quarter FROM d), extract(month FROM d),
           (ARRAY['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août',
                  'septembre', 'octobre', 'novembre', 'décembre'])[extract(month FROM d)]
    FROM generate_series(date '1994-01-01',
                         make_date(extract(year FROM current_date)::integer + 1, 12, 31),
                         interval '1 day') AS g(jour)
    CROSS JOIN LATERAL (SELECT g.jour::date AS d) AS x;

    -- Départements, avec la population du dernier millésime
    INSERT INTO gold.dim_departement VALUES (-1, '-1', 'Non renseigné', NULL, NULL, false, NULL, NULL);
    INSERT INTO gold.dim_departement
    SELECT row_number() OVER (ORDER BY d.code_departement), d.code_departement, d.departement_libelle,
           d.code_region, r.region_libelle, d.est_outre_mer, p.population_municipale, p.annee
    FROM silver.ref_departement d
    LEFT JOIN silver.ref_region r USING (code_region)
    LEFT JOIN LATERAL (SELECT population_municipale, annee FROM silver.population_departement p
                       WHERE p.code_departement = d.code_departement
                       ORDER BY annee DESC LIMIT 1) p ON true;

    -- Activités
    INSERT INTO gold.dim_activite VALUES (-1, '-1', 'Inconnue', 'inconnue');
    INSERT INTO gold.dim_activite
    SELECT row_number() OVER (ORDER BY activite_code), activite_code, activite_libelle, famille
    FROM silver.ref_activite;

    -- Organismes
    INSERT INTO gold.dim_certificateur VALUES (-1, 'Inconnu', false);
    INSERT INTO gold.dim_certificateur
    SELECT certificateur_id, certificateur_libelle, est_dispense FROM silver.ref_certificateur;

    ANALYZE gold.dim_date, gold.dim_departement, gold.dim_activite, gold.dim_certificateur;

    -- Faits : versions courantes seulement
    INSERT INTO gold.fait_certification_activite
        (operateur_id, certificateur_id, activite_id, departement_id, date_engagement_id)
    SELECT o.operateur_id,
           coalesce(dc.certificateur_id, -1),
           coalesce(da.activite_id, -1),
           coalesce(dd.departement_id, -1),
           coalesce(dt.date_id, -1)
    FROM silver.certification c
    JOIN silver.operateur o              ON o.numero_bio = c.numero_bio
    JOIN silver.certification_activite a ON a.certification_version_id = c.certification_version_id
    LEFT JOIN gold.dim_certificateur dc  ON dc.certificateur_id = c.certificateur_id
    LEFT JOIN gold.dim_activite da       ON da.activite_code = a.activite_code
    LEFT JOIN gold.dim_departement dd    ON dd.code_departement = o.code_departement
    LEFT JOIN gold.dim_date dt           ON dt.date = c.date_engagement
    WHERE c.est_courant;

    ANALYZE gold.fait_certification_activite;

    -- Mouvements. Entrée : une version ouverte un jour où l'opérateur n'avait aucune version
    -- en cours la veille (hors chargement initial). Sortie : une version fermée un jour où
    -- l'opérateur n'en garde aucune en cours. Un changement d'activité ou d'organisme n'est
    -- ni l'un ni l'autre. DISTINCT ON : un seul mouvement par opérateur, date et type.
    INSERT INTO gold.fait_mouvement
        (operateur_id, date_mouvement_id, type_mouvement, certificateur_id, departement_id)
    SELECT o.operateur_id, coalesce(dt.date_id, -1), m.type_mouvement,
           coalesce(dc.certificateur_id, -1), coalesce(dd.departement_id, -1)
    FROM (
        SELECT DISTINCT ON (v.numero_bio, v.date_debut)
               v.numero_bio, v.date_debut AS date_mouvement, 'ENTREE' AS type_mouvement, v.certificateur_id
        FROM silver.certification v
        WHERE NOT v.est_chargement_initial
          AND NOT EXISTS (SELECT 1 FROM silver.certification w
                          WHERE w.numero_bio = v.numero_bio AND w.date_debut < v.date_debut
                            AND (w.date_fin IS NULL OR w.date_fin >= v.date_debut))
        ORDER BY v.numero_bio, v.date_debut, v.certificateur_id
    ) m
    JOIN silver.operateur o              ON o.numero_bio = m.numero_bio
    LEFT JOIN gold.dim_date dt           ON dt.date = m.date_mouvement
    LEFT JOIN gold.dim_certificateur dc  ON dc.certificateur_id = m.certificateur_id
    LEFT JOIN gold.dim_departement dd    ON dd.code_departement = o.code_departement
    UNION ALL
    SELECT o.operateur_id, coalesce(dt.date_id, -1), m.type_mouvement,
           coalesce(dc.certificateur_id, -1), coalesce(dd.departement_id, -1)
    FROM (
        SELECT DISTINCT ON (v.numero_bio, v.date_fin)
               v.numero_bio, v.date_fin AS date_mouvement, 'SORTIE' AS type_mouvement, v.certificateur_id
        FROM silver.certification v
        WHERE v.date_fin IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM silver.certification w
                          WHERE w.numero_bio = v.numero_bio AND w.date_debut <= v.date_fin
                            AND (w.date_fin IS NULL OR w.date_fin > v.date_fin))
        ORDER BY v.numero_bio, v.date_fin, v.certificateur_id
    ) m
    JOIN silver.operateur o              ON o.numero_bio = m.numero_bio
    LEFT JOIN gold.dim_date dt           ON dt.date = m.date_mouvement
    LEFT JOIN gold.dim_certificateur dc  ON dc.certificateur_id = m.certificateur_id
    LEFT JOIN gold.dim_departement dd    ON dd.code_departement = o.code_departement;

    ANALYZE gold.fait_mouvement;
$$;

RESET ROLE;
