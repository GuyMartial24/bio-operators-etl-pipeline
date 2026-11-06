-- Tables du schéma audit : traçabilité des exécutions, des rejets et des contrôles qualité.
-- Détail des colonnes : docs/dictionnaire_donnees.md, schéma audit.

-- Les scripts d'initialisation tournent en super-utilisateur. On crée les tables en tant qu'etl_writer,
-- pour qu'il en soit propriétaire et que les droits automatiques (DEFAULT PRIVILEGES) s'appliquent.
SET ROLE etl_writer;

-- 1. Une ligne par exécution d'un job Talend
CREATE TABLE audit.execution (
    execution_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dag_run_id          text,
    job_nom             text        NOT NULL,
    couche              text        NOT NULL CHECK (couche IN ('bronze', 'silver', 'gold')),
    date_copie          date,
    date_debut          timestamptz NOT NULL DEFAULT now(),
    date_fin            timestamptz,
    statut              text        NOT NULL DEFAULT 'EN_COURS'
                                    CHECK (statut IN ('EN_COURS', 'SUCCES', 'ECHEC')),
    nb_lignes_lues      integer     CHECK (nb_lignes_lues >= 0),
    nb_lignes_ecrites   integer     CHECK (nb_lignes_ecrites >= 0),
    nb_lignes_rejetees  integer     CHECK (nb_lignes_rejetees >= 0),
    message             text,
    CONSTRAINT execution_dates_coherentes CHECK (date_fin IS NULL OR date_fin >= date_debut),
    CONSTRAINT execution_fin_si_terminee  CHECK (statut = 'EN_COURS' OR date_fin IS NOT NULL)
);

CREATE INDEX execution_job_date_idx ON audit.execution (job_nom, date_copie);

COMMENT ON TABLE  audit.execution IS 'Une ligne par exécution d''un job Talend : début, fin, statut et volumes. Rétention : 2 ans';
COMMENT ON COLUMN audit.execution.execution_id       IS 'Clé technique générée';
COMMENT ON COLUMN audit.execution.dag_run_id         IS 'Identifiant de l''exécution Airflow (vide pour un lancement manuel)';
COMMENT ON COLUMN audit.execution.job_nom            IS 'Nom du job Talend, par exemple bronze_agence_bio';
COMMENT ON COLUMN audit.execution.couche             IS 'Couche alimentée : bronze, silver ou gold';
COMMENT ON COLUMN audit.execution.date_copie         IS 'Version de la source traitée';
COMMENT ON COLUMN audit.execution.date_debut         IS 'Début du job';
COMMENT ON COLUMN audit.execution.date_fin           IS 'Fin du job (vide tant qu''il tourne)';
COMMENT ON COLUMN audit.execution.statut             IS 'EN_COURS, SUCCES ou ECHEC';
COMMENT ON COLUMN audit.execution.nb_lignes_lues     IS 'Lignes lues en entrée';
COMMENT ON COLUMN audit.execution.nb_lignes_ecrites  IS 'Lignes écrites en sortie';
COMMENT ON COLUMN audit.execution.nb_lignes_rejetees IS 'Lignes envoyées dans audit.rejet';
COMMENT ON COLUMN audit.execution.message            IS 'Message d''erreur en cas d''échec';

-- 2. Une ligne par ligne refusée (ou fusionnée) par un job
CREATE TABLE audit.rejet (
    rejet_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    execution_id       bigint      NOT NULL REFERENCES audit.execution (execution_id),
    table_source       text        NOT NULL,
    hash_ligne_source  char(32),
    table_cible        text        NOT NULL,
    motif_code         text        NOT NULL,
    motif_detail       text,
    ligne_source       jsonb       NOT NULL,
    date_rejet         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX rejet_execution_idx ON audit.rejet (execution_id);

COMMENT ON TABLE  audit.rejet IS 'Lignes refusées ou fusionnées par les jobs, avec leur motif. Peut contenir des noms de personnes : rétention 90 jours';
COMMENT ON COLUMN audit.rejet.rejet_id          IS 'Clé technique générée';
COMMENT ON COLUMN audit.rejet.execution_id      IS 'Exécution qui a rejeté la ligne';
COMMENT ON COLUMN audit.rejet.table_source      IS 'Table lue, par exemple bronze.agence_bio_operateur';
COMMENT ON COLUMN audit.rejet.hash_ligne_source IS '_hash_ligne de la ligne bronze, pour la retrouver';
COMMENT ON COLUMN audit.rejet.table_cible       IS 'Table visée, par exemple silver.certification';
COMMENT ON COLUMN audit.rejet.motif_code        IS 'Code du motif : NUMERO_BIO_ABSENT, ACTIVITE_INCONNUE, DOUBLON_FUSIONNE...';
COMMENT ON COLUMN audit.rejet.motif_detail      IS 'Explication lisible du motif';
COMMENT ON COLUMN audit.rejet.ligne_source      IS 'Ligne d''origine, colonne par colonne, en JSON';
COMMENT ON COLUMN audit.rejet.date_rejet        IS 'Horodatage du rejet';

-- 3. Une ligne par contrôle exécuté par un notebook de qualité
CREATE TABLE audit.controle_qualite (
    controle_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    execution_id    bigint      REFERENCES audit.execution (execution_id),
    couche          text        NOT NULL CHECK (couche IN ('bronze', 'silver', 'gold')),
    notebook        text        NOT NULL,
    nom_controle    text        NOT NULL,
    valeur_mesuree  numeric,
    seuil           numeric,
    statut          text        NOT NULL CHECK (statut IN ('OK', 'ALERTE', 'ECHEC')),
    commentaire     text,
    date_controle   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX controle_qualite_execution_idx ON audit.controle_qualite (execution_id);

COMMENT ON TABLE  audit.controle_qualite IS 'Résultats des contrôles qualité des notebooks. ECHEC arrête la chaîne Airflow. Rétention : 2 ans';
COMMENT ON COLUMN audit.controle_qualite.controle_id    IS 'Clé technique générée';
COMMENT ON COLUMN audit.controle_qualite.execution_id   IS 'Exécution du job contrôlé';
COMMENT ON COLUMN audit.controle_qualite.couche         IS 'Couche contrôlée : bronze, silver ou gold';
COMMENT ON COLUMN audit.controle_qualite.notebook       IS 'Notebook qui a fait le contrôle, par exemple qualite/02_silver.ipynb';
COMMENT ON COLUMN audit.controle_qualite.nom_controle   IS 'Nom du contrôle, par exemple taux_rattachement_inconnu';
COMMENT ON COLUMN audit.controle_qualite.valeur_mesuree IS 'Résultat mesuré';
COMMENT ON COLUMN audit.controle_qualite.seuil          IS 'Seuil d''alerte ou d''échec';
COMMENT ON COLUMN audit.controle_qualite.statut         IS 'OK, ALERTE (la chaîne continue) ou ECHEC (la chaîne s''arrête)';
COMMENT ON COLUMN audit.controle_qualite.commentaire    IS 'Détail du résultat';
COMMENT ON COLUMN audit.controle_qualite.date_controle  IS 'Horodatage du contrôle';

-- 4. Moindre privilège : 03_privileges.sql donne à qa_reader le droit d'insérer dans toutes les tables d'audit.
-- Les notebooks n'écrivent que leurs résultats : on lui retire l'insertion sur les deux autres tables.
REVOKE INSERT ON audit.execution, audit.rejet FROM qa_reader;

RESET ROLE;
