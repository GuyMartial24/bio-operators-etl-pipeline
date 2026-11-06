-- Tables du schéma bronze : copie fidèle des sources.
-- Règle : toutes les colonnes de la source en text, sans transformation, ni clé primaire.
-- Un chargement brut ne doit jamais échouer sur un format : c'est silver qui contrôle.
-- Chaque table reçoit les mêmes 6 colonnes techniques, préfixées par _ (voir docs/modele_donnees.md, § 3.2).

SET ROLE etl_writer;

-- 1. Annuaire des opérateurs bio (Agence Bio), quotidien
CREATE TABLE bronze.agence_bio_operateur (
    siret                      text,
    numero_bio                 text,
    denomination               text,
    code_postal_siege_social   text,
    dateengagement             text,
    activites                  text,
    organisme_certificateur    text,
    _execution_id     bigint      NOT NULL REFERENCES audit.execution (execution_id),
    _date_copie       date        NOT NULL,
    _fichier_source   text        NOT NULL,
    _numero_ligne     integer     NOT NULL,
    _hash_ligne       char(32)    NOT NULL,
    _date_chargement  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX agence_bio_operateur_date_copie_idx ON bronze.agence_bio_operateur (_date_copie);
COMMENT ON TABLE bronze.agence_bio_operateur IS
    'Annuaire Agence Bio, une ligne par ligne du fichier et par copie. Rétention : 30 dernières copies. Données personnelles (denomination)';

-- 2. Code officiel géographique (INSEE) : départements et régions
CREATE TABLE bronze.insee_cog_departement (
    dep       text,
    reg       text,
    cheflieu  text,
    tncc      text,
    ncc       text,
    nccenr    text,
    libelle   text,
    _execution_id     bigint      NOT NULL REFERENCES audit.execution (execution_id),
    _date_copie       date        NOT NULL,
    _fichier_source   text        NOT NULL,
    _numero_ligne     integer     NOT NULL,
    _hash_ligne       char(32)    NOT NULL,
    _date_chargement  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE bronze.insee_cog_departement IS
    'COG INSEE, départements. Rétention : une version par millésime';

CREATE TABLE bronze.insee_cog_region (
    reg       text,
    cheflieu  text,
    tncc      text,
    ncc       text,
    nccenr    text,
    libelle   text,
    _execution_id     bigint      NOT NULL REFERENCES audit.execution (execution_id),
    _date_copie       date        NOT NULL,
    _fichier_source   text        NOT NULL,
    _numero_ligne     integer     NOT NULL,
    _hash_ligne       char(32)    NOT NULL,
    _date_chargement  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE bronze.insee_cog_region IS
    'COG INSEE, régions. Rétention : une version par millésime';

-- 3. Populations légales par département (INSEE)
CREATE TABLE bronze.insee_population_departement (
    reg          text,
    region       text,
    dep          text,
    departement  text,
    nbarr        text,
    nbcan        text,
    nbcom        text,
    pmun         text,
    ptot         text,
    _execution_id     bigint      NOT NULL REFERENCES audit.execution (execution_id),
    _date_copie       date        NOT NULL,
    _fichier_source   text        NOT NULL,
    _numero_ligne     integer     NOT NULL,
    _hash_ligne       char(32)    NOT NULL,
    _date_chargement  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE bronze.insee_population_departement IS
    'Populations légales INSEE par département. Rétention : une version par millésime';

-- 4. Colonnes techniques : même description pour toutes les tables bronze
DO $$
DECLARE t text;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'bronze' LOOP
        EXECUTE format('COMMENT ON COLUMN bronze.%I._execution_id    IS %L', t, 'Exécution qui a chargé la ligne (audit.execution)');
        EXECUTE format('COMMENT ON COLUMN bronze.%I._date_copie      IS %L', t, 'Date de la version de la source');
        EXECUTE format('COMMENT ON COLUMN bronze.%I._fichier_source  IS %L', t, 'Nom du fichier lu');
        EXECUTE format('COMMENT ON COLUMN bronze.%I._numero_ligne    IS %L', t, 'Numéro de la ligne dans le fichier, hors en-tête');
        EXECUTE format('COMMENT ON COLUMN bronze.%I._hash_ligne      IS %L', t, 'Empreinte MD5 de la ligne brute');
        EXECUTE format('COMMENT ON COLUMN bronze.%I._date_chargement IS %L', t, 'Horodatage de l''écriture en base');
    END LOOP;
END $$;

RESET ROLE;
