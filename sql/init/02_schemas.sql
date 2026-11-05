-- Schémas de l'architecture en médaillon, plus le schéma d'audit.
-- AUTHORIZATION etl_writer : le rôle de Talend en est propriétaire,
-- donc toutes les tables qu'il créera lui appartiendront.

CREATE SCHEMA bronze AUTHORIZATION etl_writer;
CREATE SCHEMA silver AUTHORIZATION etl_writer;
CREATE SCHEMA gold   AUTHORIZATION etl_writer;
CREATE SCHEMA audit  AUTHORIZATION etl_writer;

COMMENT ON SCHEMA bronze IS 'Données brutes, telles que reçues. Jamais modifiées, supprimées seulement par la règle de rétention';
COMMENT ON SCHEMA silver IS 'Données nettoyées, typées, jointes et historisées (SCD 2). Contient des données personnelles : accès restreint';
COMMENT ON SCHEMA gold   IS 'Modèle en étoile et indicateurs pour Power BI. Aucune donnée personnelle';
COMMENT ON SCHEMA audit  IS 'Traçabilité : exécutions des jobs, lignes rejetées, résultats des contrôles qualité';
