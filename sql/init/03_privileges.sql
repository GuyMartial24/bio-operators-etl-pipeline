-- Droits d'accès. Règle : on retire tout par défaut, puis on donne à chaque rôle le strict nécessaire.
-- :"DBNAME" est une variable de psql qui contient le nom de la base courante.

-- 1. Par défaut, personne ne peut se connecter ni créer d'objets
REVOKE ALL ON DATABASE :"DBNAME" FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE :"DBNAME" TO etl_writer, bi_reader, qa_reader;

-- 2. Power BI : lecture seule, sur gold uniquement
GRANT USAGE ON SCHEMA gold TO bi_reader;

-- 3. Notebooks de contrôle : lecture sur toutes les couches
GRANT USAGE ON SCHEMA bronze, silver, gold, audit TO qa_reader;

-- 4. Droits sur les tables futures.
-- Les tables n'existent pas encore : DEFAULT PRIVILEGES dit
-- « chaque table que etl_writer créera plus tard dans ce schéma recevra ces droits ».
ALTER DEFAULT PRIVILEGES FOR ROLE etl_writer IN SCHEMA gold
    GRANT SELECT ON TABLES TO bi_reader;

ALTER DEFAULT PRIVILEGES FOR ROLE etl_writer IN SCHEMA bronze, silver, gold, audit
    GRANT SELECT ON TABLES TO qa_reader;

ALTER DEFAULT PRIVILEGES FOR ROLE etl_writer IN SCHEMA audit
    GRANT INSERT ON TABLES TO qa_reader;

ALTER DEFAULT PRIVILEGES FOR ROLE etl_writer IN SCHEMA audit
    GRANT USAGE ON SEQUENCES TO qa_reader;
