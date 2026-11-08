# Observatoire territorial de la filière bio

**Auteur : Martial GADJEU** | Data & AI Engineer

Pipeline de données de bout en bout qui transforme l'annuaire public des **88 000 opérateurs bio certifiés en France**
en tableau de bord de pilotage : où la filière manque-t-elle de transformateurs, comment se développe-t-elle,
et qui la certifie ?

**Talend** (ETL) · **PostgreSQL** (architecture médaillon, SCD 2) · **Airflow** (orchestration quotidienne) ·
**Power BI** (DAX) · **Docker** · **GitHub Actions** (CI)

![Page Structure du rapport Power BI](docs/images/powerbi_structure.png)

## Ce que montre l'observatoire

| Page | Question | Résultat sur la copie du 8 novembre 2026 |
|---|---|---|
| **Structure** | Où produit-on sans transformer ? | 62 005 producteurs pour 42 092 transformateurs. **7 déserts de transformation**, dont 6 en Occitanie : le Gers compte 1 940 producteurs pour un ratio de transformation de 18 % (68 % en moyenne) |
| **Développement** | Comment la filière grandit-elle ? | Forte croissance de 2015 à 2021, recul en 2022-2023. Entrées et sorties d'opérateurs suivies chaque jour grâce à l'historique |
| **Marché** | Qui certifie, avec quelle concentration ? | Marché **très concentré** (indice HHI de 3 782) : Ecocert certifie 56 % des opérateurs, jusqu'à 97 % en Guyane |

| Développement | Marché |
|---|---|
| ![Page Développement](docs/images/powerbi_developpement.png) | ![Page Marché](docs/images/powerbi_marche.png) |

**Consulter le rapport** : [export PDF des trois pages](docs/observatoire_bio.pdf), ou le fichier Power BI complet
avec ses données (`observatoire_bio.pbix`) dans la [dernière version publiée](../../releases/latest),
à ouvrir avec Power BI Desktop (gratuit).

## Architecture

```mermaid
flowchart LR
    subgraph Sources["Sources ouvertes"]
        A["Annuaire Agence Bio<br/>(data.gouv.fr, quotidien)"]
        I["INSEE : départements,<br/>régions, populations"]
    end
    subgraph Airflow["Airflow : DAG pipeline_bio, chaque jour à 6 h"]
        T["telecharger_annuaire"]
        subgraph Talend["Jobs Talend exportés"]
            B1["bronze_agence_bio"]
            B2["bronze_insee"]
            S1["silver_referentiels"]
            S2["silver_annuaire"]
            G["gold_etoile"]
        end
        Q["controle_qualite<br/>(notebook, papermill)"]
    end
    subgraph PG["PostgreSQL 17"]
        BR[("bronze<br/>copie brute")]
        SI[("silver<br/>nettoyé, historisé")]
        GO[("gold<br/>modèle en étoile")]
        AU[("audit")]
    end
    PBI["Power BI<br/>3 pages, mesures DAX"]

    A --> T --> B1
    I --> B2
    B1 & B2 --> BR
    S1 & S2 --> SI
    G --> GO
    GO --> Q
    GO --> PBI
    B1 & B2 & S1 & S2 & G & Q -.-> AU
```

| Couche | Contenu | Points clés |
|---|---|---|
| **bronze** | Copie fidèle des fichiers, tout en texte | Colonnes techniques (exécution, date de copie, fichier, ligne, empreinte MD5) ; idempotent (purge puis rechargement, dans une transaction) |
| **silver** | Données nettoyées et typées | SIRET contrôlé par la clé de Luhn, code postal, département déduit (Corse, outre-mer, étranger) ; opérateurs en **SCD 1**, certifications historisées en **SCD 2** ; rejets tracés dans `audit.rejet` |
| **gold** | Modèle en **constellation** : deux tables de faits (état du jour, entrées et sorties) et quatre dimensions conformes | Aucune donnée personnelle : l'opérateur n'y est qu'un pseudonyme ; Power BI n'a accès qu'à ce schéma |
| **audit** | Exécutions, rejets, contrôles qualité | Chaque job ouvre et ferme sa ligne d'audit, même en cas d'échec |

## Choix techniques

- **Talend pour le nettoyage ligne par ligne**, **SQL pour les fusions par ensembles** : la routine Java `Nettoyage`
  et le tMap (avec jointure sur le référentiel des départements) remplissent une table de travail ; des procédures
  stockées font la SCD 2, testées en CI sur deux copies successives.
- **Idempotence et atomicité** partout : relancer un jour ne crée aucun doublon ; un échec annule tout (rollback),
  tandis que l'audit, sur une connexion séparée, garde la trace de l'échec.
- **Copies traitées dans l'ordre** : une procédure refuse une copie plus ancienne que la dernière historisée, et
  Airflow n'exécute qu'un jour à la fois.
- **Moindre privilège** : un rôle par usage (`etl_writer`, `bi_reader` limité à gold, `qa_reader`, `airflow` sans
  accès aux données). Aucun secret dans Git : fichiers de contexte et `.env` exclus, mots de passe lus dans
  l'environnement.
- **Jobs portables** : un seul export Talend (*Build Job*) tourne sur le poste et dans le conteneur Airflow ; le
  fichier de réglages est choisi par la variable `TALEND_CONTEXTE`.
- **Rapport versionné comme du code** : format projet Power BI (`.pbip`, modèle TMDL), chaque mesure DAX est lisible
  dans Git.
- **Chiffres vérifiés** : chaque indicateur du rapport a été recalculé en SQL sur gold.

## Qualité et tests

- **CI GitHub Actions** : à chaque push, la base est créée sur un PostgreSQL vierge et 13 séries de tests vérifient
  schémas, rôles, droits, contraintes, la SCD 2 et l'absence de données personnelles en gold
  ([`sql/tests/test_init.sql`](sql/tests/test_init.sql)).
- **Contrôle qualité quotidien** : un notebook exécuté par Airflow mesure 13 indicateurs sur les données réelles
  (volume de la copie, SIRET valides, unicité des versions SCD 2, rapprochements silver / gold…) et les enregistre ;
  un échec fait passer la tâche en rouge ([`notebooks/qualite`](notebooks/qualite)).

## Lancer le projet

Prérequis : Docker Desktop, et Talaxie Open Studio 8.9 pour modifier ou réexporter les jobs.

```bash
cp .env.example .env                       # puis choisir les mots de passe
cp talend/contexte_docker.properties.example talend/contexte_docker.properties   # mot de passe d'etl_writer
docker compose up -d                       # PostgreSQL (schémas, rôles, tables) et Airflow
```

- Exporter les cinq jobs depuis Talend (*Build Job*, type autonome) dans `talend/build/`.
- Ouvrir Airflow sur http://localhost:8080 (utilisateur `admin`, mot de passe dans
  `/opt/airflow/auth/passwords.json` du conteneur), puis activer le DAG `pipeline_bio`.
- Ouvrir `powerbi/observatoire_bio.pbip` dans Power BI Desktop, se connecter avec `bi_reader`.

## Structure du dépôt

| Dossier | Contenu |
|---|---|
| [`talend/`](talend) | Projet Talend : 5 jobs, routines `Empreinte` et `Nettoyage`, connexion et contexte |
| [`sql/init/`](sql/init) | Création de la base : rôles, schémas, droits, tables, procédures de fusion |
| [`sql/tests/`](sql/tests) | Tests exécutés par la CI |
| [`airflow/`](airflow) | Image Docker (Airflow 3.3 et Java 17) et DAG `pipeline_bio` |
| [`notebooks/`](notebooks) | Exploration des sources, contrôle qualité |
| [`powerbi/`](powerbi) | Rapport (format projet), fond de carte des départements |
| [`docs/`](docs) | [Cadrage](docs/cadrage.md), [modèle de données](docs/modele_donnees.md), [dictionnaire](docs/dictionnaire_donnees.md), [journal du projet](docs/journal.md) |

## Limites connues

- La source ne conserve que la dernière version de l'annuaire : un jour sans exécution est une copie perdue.
  L'historique commence le 5 novembre 2026.
- Le graphique par année d'engagement ne montre que les opérateurs encore actifs (biais du survivant) ; les
  vraies entrées et sorties ne sont connues que depuis le début du suivi.
- Mayotte est absente des populations légales 2023 : pas d'indicateur par habitant pour ce département.
- Le département est déduit du code postal du siège : quelques communes sont desservies par le code postal d'un
  département voisin.

## Données

Annuaire des opérateurs bio : Agence Bio, sur [data.gouv.fr](https://www.data.gouv.fr/fr/datasets/professionnels-engages-en-bio/)
(Licence Ouverte). Code officiel géographique et populations légales : INSEE. Contours des départements :
fichier `departements-version-simplifiee.geojson` du projet france-geojson, converti en TopoJSON
([`powerbi/cartes`](powerbi/cartes)).

## Auteur

**Martial GADJEU** | Data & AI Engineer
