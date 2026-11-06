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

-- 2. Base officielle des codes postaux (La Poste)
CREATE TABLE bronze.laposte_code_postal (
    code_commune_insee      text,
    nom_de_la_commune       text,
    code_postal             text,
    libelle_d_acheminement  text,
    ligne_5                 text,
    _execution_id     bigint      NOT NULL REFERENCES audit.execution (execution_id),
    _date_copie       date        NOT NULL,
    _fichier_source   text        NOT NULL,
    _numero_ligne     integer     NOT NULL,
    _hash_ligne       char(32)    NOT NULL,
    _date_chargement  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE bronze.laposte_code_postal IS
    'Codes postaux La Poste (fichier en ISO-8859-1). Rétention : dernière version';

-- 3. Code officiel géographique (INSEE) : communes, départements, régions
CREATE TABLE bronze.insee_cog_commune (
    typecom    text,
    com        text,
    reg        text,
    dep        text,
    ctcd       text,
    arr        text,
    tncc       text,
    ncc        text,
    nccenr     text,
    libelle    text,
    can        text,
    comparent  text,
    _execution_id     bigint      NOT NULL REFERENCES audit.execution (execution_id),
    _date_copie       date        NOT NULL,
    _fichier_source   text        NOT NULL,
    _numero_ligne     integer     NOT NULL,
    _hash_ligne       char(32)    NOT NULL,
    _date_chargement  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE bronze.insee_cog_commune IS
    'COG INSEE, communes. Grain : type x code (un code peut être partagé par une COM et une COMD). Rétention : une version par millésime';

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

-- 4. Populations légales par département (INSEE)
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

-- 5. Recensement agricole 2020 (Agreste), format long, filtré sur geographie = DEP à la lecture
CREATE TABLE bronze.agreste_ra2020 (
    nom                   text,
    annref                text,
    geographie            text,
    code_geo              text,
    n122_lib              text,
    n122_mod              text,
    n122                  text,
    n110d_lib             text,
    n110d_mod             text,
    n110d                 text,
    ra2020_001_dim3_lib   text,
    ra2020_001_dim3_mod   text,
    ra2020_001_dim3       text,
    valeur_extrapolee     text,
    valeur_brute          text,
    nb_etab               text,
    imputation            text,
    _execution_id     bigint      NOT NULL REFERENCES audit.execution (execution_id),
    _date_copie       date        NOT NULL,
    _fichier_source   text        NOT NULL,
    _numero_ligne     integer     NOT NULL,
    _hash_ligne       char(32)    NOT NULL,
    _date_chargement  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE bronze.agreste_ra2020 IS
    'Recensement agricole 2020, lignes départementales seulement (filtre à la lecture). Rétention : définitive';

-- 6. SIRENE StockEtablissement, filtré à la lecture sur les SIRET de l'annuaire.
-- Seules les colonnes utiles sont gardées (minimisation RGPD, voir notebooks/exploration/04_sirene.ipynb).
CREATE TABLE bronze.sirene_etablissement (
    siren                                              text,
    nic                                                text,
    siret                                              text,
    statut_diffusion_etablissement                     text,
    date_creation_etablissement                        text,
    etat_administratif_etablissement                   text,
    date_debut                                         text,
    etablissement_siege                                text,
    nombre_periodes_etablissement                      text,
    date_dernier_traitement_etablissement              text,
    activite_principale_etablissement                  text,
    nomenclature_activite_principale_etablissement     text,
    activite_principale_naf25_etablissement            text,
    activite_principale_registre_metiers_etablissement text,
    tranche_effectifs_etablissement                    text,
    annee_effectifs_etablissement                      text,
    caractere_employeur_etablissement                  text,
    code_postal_etablissement                          text,
    code_commune_etablissement                         text,
    libelle_commune_etablissement                      text,
    code_pays_etranger_etablissement                   text,
    coordonnee_lambert_abscisse_etablissement          text,
    coordonnee_lambert_ordonnee_etablissement          text,
    _execution_id     bigint      NOT NULL REFERENCES audit.execution (execution_id),
    _date_copie       date        NOT NULL,
    _fichier_source   text        NOT NULL,
    _numero_ligne     integer     NOT NULL,
    _hash_ligne       char(32)    NOT NULL,
    _date_chargement  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sirene_etablissement_date_copie_idx ON bronze.sirene_etablissement (_date_copie);
COMMENT ON TABLE bronze.sirene_etablissement IS
    'SIRENE, établissements dont le SIRET est dans l''annuaire. Valeurs [ND] gardées telles quelles. Rétention : 3 derniers stocks';

-- 7. Colonnes techniques : même description pour toutes les tables bronze
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
