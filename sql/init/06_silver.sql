-- Tables du schéma silver : données nettoyées, typées et historisées.
-- Règles : une clé primaire par table, des clés étrangères entre tables,
-- des CHECK sur les domaines (codes, statuts) et sur la cohérence entre colonnes.
-- Les tables sont vides : elles sont alimentées par les jobs silver_referentiels et silver_annuaire.
-- Description complète : docs/dictionnaire_donnees.md, docs/modele_donnees.md (§ 3.3).

SET ROLE etl_writer;

-- 1. Référentiels géographiques (COG INSEE)
CREATE TABLE silver.ref_region (
    code_region     text     PRIMARY KEY CHECK (code_region ~ '^[0-9]{2}$'),
    region_libelle  text     NOT NULL,
    millesime_cog   smallint NOT NULL
);
COMMENT ON TABLE  silver.ref_region IS 'Régions françaises, une ligne par région (COG INSEE)';
COMMENT ON COLUMN silver.ref_region.code_region    IS 'Code INSEE de la région (84)';
COMMENT ON COLUMN silver.ref_region.region_libelle IS 'Nom de la région';
COMMENT ON COLUMN silver.ref_region.millesime_cog  IS 'Année du COG';

CREATE TABLE silver.ref_departement (
    code_departement     text     PRIMARY KEY
                                  CHECK (code_departement ~ '^([0-9]{2}|2[AB]|97[1-6])$'),
    departement_libelle  text     NOT NULL,
    code_region          text     REFERENCES silver.ref_region (code_region),
    est_outre_mer        boolean  NOT NULL,
    millesime_cog        smallint NOT NULL,
    -- Les membres spéciaux (99 étranger, 00 inconnu) n'ont pas de région ; les vrais départements en ont une.
    CONSTRAINT ref_departement_region_si_reel
        CHECK ((code_departement IN ('99', '00')) = (code_region IS NULL)),
    CONSTRAINT ref_departement_outre_mer
        CHECK (est_outre_mer = (length(code_departement) = 3))
);
COMMENT ON TABLE  silver.ref_departement IS
    'Départements (COG INSEE), plus deux membres spéciaux : 99 étranger, 00 inconnu';
COMMENT ON COLUMN silver.ref_departement.code_departement    IS '01…95, 2A, 2B, 971…976 ; 99 étranger, 00 inconnu';
COMMENT ON COLUMN silver.ref_departement.departement_libelle IS 'Nom du département';
COMMENT ON COLUMN silver.ref_departement.code_region         IS 'Région du département, vide pour 99 et 00';
COMMENT ON COLUMN silver.ref_departement.est_outre_mer       IS 'Vrai pour les codes à 3 caractères';
COMMENT ON COLUMN silver.ref_departement.millesime_cog       IS 'Année du COG';

CREATE TABLE silver.population_departement (
    code_departement       text     REFERENCES silver.ref_departement (code_departement),
    annee                  smallint,
    population_municipale  integer  NOT NULL CHECK (population_municipale > 0),
    PRIMARY KEY (code_departement, annee)
);
COMMENT ON TABLE  silver.population_departement IS
    'Population municipale par département et par année (INSEE). Mayotte absente du millésime 2023';
COMMENT ON COLUMN silver.population_departement.code_departement      IS 'Département';
COMMENT ON COLUMN silver.population_departement.annee                 IS 'Année de référence de la population';
COMMENT ON COLUMN silver.population_departement.population_municipale IS 'Population municipale (INSEE PMUN)';

-- 2. Référentiels de l'annuaire
CREATE TABLE silver.ref_activite (
    activite_code     text PRIMARY KEY CHECK (activite_code ~ '^[A-Z_]+$'),
    activite_libelle  text NOT NULL UNIQUE,
    famille           text NOT NULL
                      CHECK (famille IN ('production', 'transformation', 'distribution', 'logistique', 'echanges'))
);
COMMENT ON TABLE  silver.ref_activite IS 'Les 8 activités de l''annuaire et leur famille';
COMMENT ON COLUMN silver.ref_activite.activite_code    IS 'Code en majuscules sans accent (PREPARATION)';
COMMENT ON COLUMN silver.ref_activite.activite_libelle IS 'Libellé de l''annuaire (Préparation)';
COMMENT ON COLUMN silver.ref_activite.famille          IS 'production, transformation, distribution, logistique, echanges';

CREATE TABLE silver.ref_certificateur (
    certificateur_id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    certificateur_libelle      text    NOT NULL UNIQUE,
    est_dispense               boolean NOT NULL,
    date_premiere_observation  date    NOT NULL
);
COMMENT ON TABLE  silver.ref_certificateur IS 'Organismes certificateurs observés dans l''annuaire';
COMMENT ON COLUMN silver.ref_certificateur.certificateur_id          IS 'Clé technique';
COMMENT ON COLUMN silver.ref_certificateur.certificateur_libelle     IS 'Nom de l''organisme dans l''annuaire';
COMMENT ON COLUMN silver.ref_certificateur.est_dispense              IS 'Vrai pour « Dispense de certification »';
COMMENT ON COLUMN silver.ref_certificateur.date_premiere_observation IS 'Première copie où l''organisme apparaît';

-- 3. Opérateur : état courant (SCD 1)
CREATE TABLE silver.operateur (
    operateur_id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    numero_bio                 integer NOT NULL UNIQUE,
    siret                      char(14) CHECK (siret ~ '^[0-9]{14}$'),
    siret_statut               text    NOT NULL
                               CHECK (siret_statut IN ('VALIDE', 'ABSENT', 'TEXTE_NONE', 'FORMAT_INVALIDE', 'LUHN_INVALIDE')),
    denomination               text    NOT NULL,
    code_postal                text    CHECK (code_postal ~ '^[0-9]{5}$'),
    code_postal_statut         text    NOT NULL CHECK (code_postal_statut IN ('VALIDE', 'ABSENT', 'FORMAT_INVALIDE')),
    code_departement           text    NOT NULL REFERENCES silver.ref_departement (code_departement),
    methode_rattachement       text    NOT NULL CHECK (methode_rattachement IN ('CODE_POSTAL', 'ETRANGER', 'INCONNU')),
    est_present                boolean NOT NULL,
    date_premiere_observation  date    NOT NULL,
    date_derniere_observation  date    NOT NULL,
    -- Une valeur n'est gardée que si elle est valide : le statut et la valeur se répondent.
    CONSTRAINT operateur_siret_coherent       CHECK ((siret_statut = 'VALIDE') = (siret IS NOT NULL)),
    CONSTRAINT operateur_code_postal_coherent CHECK ((code_postal_statut = 'VALIDE') = (code_postal IS NOT NULL)),
    CONSTRAINT operateur_rattachement_coherent CHECK (
        (methode_rattachement = 'INCONNU')  = (code_departement = '00') AND
        (methode_rattachement = 'ETRANGER') = (code_departement = '99')
    ),
    CONSTRAINT operateur_dates_coherentes CHECK (date_premiere_observation <= date_derniere_observation)
);
COMMENT ON TABLE  silver.operateur IS
    'Opérateurs bio, une ligne par numéro bio, état courant (SCD 1). Données personnelles (denomination, siret) : ne quittent jamais silver';
COMMENT ON COLUMN silver.operateur.operateur_id              IS 'Clé technique stable, pseudonyme utilisé en gold';
COMMENT ON COLUMN silver.operateur.numero_bio                IS 'Clé naturelle (annuaire)';
COMMENT ON COLUMN silver.operateur.siret                     IS 'SIRET nettoyé et valide, sinon vide';
COMMENT ON COLUMN silver.operateur.siret_statut              IS 'VALIDE, ABSENT, TEXTE_NONE, FORMAT_INVALIDE, LUHN_INVALIDE';
COMMENT ON COLUMN silver.operateur.denomination              IS 'Nom de l''opérateur. Donnée personnelle';
COMMENT ON COLUMN silver.operateur.code_postal               IS 'Code postal nettoyé (5 chiffres), sinon vide';
COMMENT ON COLUMN silver.operateur.code_postal_statut        IS 'VALIDE, ABSENT, FORMAT_INVALIDE';
COMMENT ON COLUMN silver.operateur.code_departement          IS 'Département de rattachement (00 inconnu, 99 étranger)';
COMMENT ON COLUMN silver.operateur.methode_rattachement      IS 'CODE_POSTAL, ETRANGER, INCONNU';
COMMENT ON COLUMN silver.operateur.est_present               IS 'Présent dans la dernière copie';
COMMENT ON COLUMN silver.operateur.date_premiere_observation IS 'Première copie où l''opérateur apparaît';
COMMENT ON COLUMN silver.operateur.date_derniere_observation IS 'Dernière copie où il apparaît';

-- 4. Certification : historique (SCD 2)
CREATE TABLE silver.certification (
    certification_version_id  bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    numero_bio                integer NOT NULL REFERENCES silver.operateur (numero_bio),
    certificateur_id          integer NOT NULL REFERENCES silver.ref_certificateur (certificateur_id),
    date_engagement           date,
    date_engagement_statut    text    NOT NULL CHECK (date_engagement_statut IN ('VALIDE', 'ABSENTE', 'FUTURE')),
    activites_liste           text    NOT NULL,
    hash_attributs            char(32) NOT NULL,
    date_debut                date    NOT NULL,
    date_fin                  date,
    est_courant               boolean NOT NULL,
    est_chargement_initial    boolean NOT NULL,
    _execution_id             bigint  NOT NULL REFERENCES audit.execution (execution_id),
    CONSTRAINT certification_date_engagement_coherente
        CHECK ((date_engagement_statut = 'VALIDE') = (date_engagement IS NOT NULL)),
    -- Intervalle semi-ouvert [date_debut, date_fin[ : une version dure au moins un jour.
    CONSTRAINT certification_dates_coherentes CHECK (date_fin IS NULL OR date_fin > date_debut),
    CONSTRAINT certification_courant_coherent CHECK (est_courant = (date_fin IS NULL))
);
-- Une seule version en cours par clé naturelle. Sert aussi à comparer la copie du jour aux versions courantes.
CREATE UNIQUE INDEX certification_une_version_courante_idx
    ON silver.certification (numero_bio, certificateur_id) WHERE est_courant;
COMMENT ON TABLE  silver.certification IS
    'Versions des certifications (opérateur × organisme), historisées en SCD 2';
COMMENT ON COLUMN silver.certification.certification_version_id IS 'Clé technique de la version';
COMMENT ON COLUMN silver.certification.numero_bio               IS 'Clé naturelle, partie 1 : l''opérateur';
COMMENT ON COLUMN silver.certification.certificateur_id         IS 'Clé naturelle, partie 2 : l''organisme';
COMMENT ON COLUMN silver.certification.date_engagement          IS 'Date d''engagement en bio. Vide si absente ou future';
COMMENT ON COLUMN silver.certification.date_engagement_statut   IS 'VALIDE, ABSENTE, FUTURE';
COMMENT ON COLUMN silver.certification.activites_liste          IS 'Codes d''activités triés, séparés par des virgules';
COMMENT ON COLUMN silver.certification.hash_attributs           IS 'MD5 de date_engagement et activites_liste : détecte un changement';
COMMENT ON COLUMN silver.certification.date_debut               IS 'Copie où la version apparaît (incluse)';
COMMENT ON COLUMN silver.certification.date_fin                 IS 'Copie où elle change ou disparaît (exclue). Vide si en cours';
COMMENT ON COLUMN silver.certification.est_courant              IS 'Vrai pour la version en cours';
COMMENT ON COLUMN silver.certification.est_chargement_initial   IS 'Créée par le premier chargement : pas une entrée dans la filière';
COMMENT ON COLUMN silver.certification._execution_id            IS 'Exécution qui a créé la version (audit.execution)';

CREATE TABLE silver.certification_activite (
    certification_version_id  bigint REFERENCES silver.certification (certification_version_id),
    activite_code             text   REFERENCES silver.ref_activite (activite_code),
    PRIMARY KEY (certification_version_id, activite_code)
);
COMMENT ON TABLE  silver.certification_activite IS 'Activités de chaque version de certification, une ligne par activité';
COMMENT ON COLUMN silver.certification_activite.certification_version_id IS 'Version de certification';
COMMENT ON COLUMN silver.certification_activite.activite_code            IS 'Activité';

-- 5. Table de travail du job silver_annuaire
-- Reçoit les lignes de l'annuaire nettoyées par Talend (une par ligne de bronze), vidée à chaque exécution.
-- Les requêtes de fusion (opérateur, certification) partent de cette table.
CREATE TABLE silver.annuaire_prepare (
    numero_bio              integer NOT NULL,
    siret                   char(14),
    siret_statut            text    NOT NULL,
    denomination            text,
    code_postal             text,
    code_postal_statut      text    NOT NULL,
    code_departement        text    NOT NULL,
    methode_rattachement    text    NOT NULL,
    date_engagement         date,
    date_engagement_statut  text    NOT NULL,
    activites               text,
    certificateur_libelle   text    NOT NULL,
    _numero_ligne           integer NOT NULL,
    _execution_id           bigint  NOT NULL
);
COMMENT ON TABLE silver.annuaire_prepare IS
    'Table de travail : lignes de l''annuaire nettoyées par silver_annuaire, avant fusion. Vidée à chaque exécution';
COMMENT ON COLUMN silver.annuaire_prepare.activites             IS 'Libellés d''activités tels que dans l''annuaire, séparés par des virgules';
COMMENT ON COLUMN silver.annuaire_prepare.certificateur_libelle IS 'Nom de l''organisme tel que dans l''annuaire';
COMMENT ON COLUMN silver.annuaire_prepare._numero_ligne         IS 'Numéro de la ligne en bronze, pour retrouver la source d''un rejet';

RESET ROLE;
