# Journal de bord du projet

Chaque étape est notée avec **ce qui a été fait**, **pourquoi**, et **ce qu'il faut savoir expliquer**.

---

## Étape 0 — Préparer le poste de travail (05/11/2026)

### WSL 2 et Ubuntu

**Ce qui a été fait :** installation d'Ubuntu 26.04 dans WSL 2 (`wsl --install -d Ubuntu`),
avec un utilisateur `guyka` membre du groupe `sudo`, puis mise à jour (`sudo apt update && sudo apt upgrade`).

**Pourquoi :**
- WSL 2 (Windows Subsystem for Linux) fait tourner un vrai noyau Linux dans Windows.
- Les outils data (Docker, Airflow, PostgreSQL) sont conçus pour Linux, et le VPS sera sous Linux.
  Travailler sous Linux en local évite les surprises au déploiement.
- On travaille avec un utilisateur normal plutôt que `root` : une erreur de commande
  ne peut pas casser tout le système, et `sudo` oblige à confirmer les actions d'administration.

**À savoir expliquer :**
- `apt update` télécharge la liste des paquets disponibles.
- `apt upgrade` installe les nouvelles versions. Il faut `sudo` car on modifie le système.

### Docker Desktop relié à Ubuntu

**Ce qui a été fait :** activation de l'intégration WSL de Docker Desktop pour Ubuntu, puis test avec `docker run hello-world`.

**Pourquoi :**
- Docker emballe une application et tout ce dont elle a besoin dans un **conteneur**.
  Le même conteneur tourne à l'identique sur le PC, dans GitHub Actions et sur le VPS.
- Docker Desktop était déjà installé. L'intégration WSL permet de taper `docker` depuis Ubuntu.
- Sur le VPS, on installera Docker Engine (la version serveur, sans interface graphique).
  Les commandes et les fichiers `docker-compose.yml` restent les mêmes.

**À savoir expliquer :**
- Une **image** est un modèle figé (par exemple `postgres:17`).
- Un **conteneur** est une image en train de tourner.
- `docker run hello-world` télécharge l'image, crée un conteneur, l'exécute et affiche un message.

---

## Étape 1 — Cadrage du cas d'usage (05/11/2026)

**Ce qui a été fait :** analyse rapide de l'annuaire bio, puis rédaction de `docs/cadrage.md`.

**Pourquoi :**
- Un projet data commence par une **question métier**, pas par la technique.
  Sans question, on ne sait ni quelles données garder ni quels indicateurs calculer.
- Le cas retenu, un observatoire territorial de la filière bio, réunit trois axes
  (structure, dynamique, marché), un utilisateur cible (Région / DRAAF) et des indicateurs définis.

**Décisions et justifications :**

| Décision | Justification |
|---|---|
| Architecture en **médaillon** (bronze / silver / gold) | Standard du métier. Le brut est toujours conservé, donc on peut tout rejouer. Chaque couche a une seule responsabilité. Les erreurs sont faciles à localiser |
| Copie quotidienne de l'annuaire | Le fichier ne contient que les opérateurs actuels. Sans copies successives, impossible de voir les sorties ou les changements de certificateur |
| Données stockées sur le **VPS** | Le pipeline y tourne tous les jours. Le PC sert seulement au développement |
| Code Python dans des **notebooks** | Le code et ses explications sont au même endroit. Airflow les exécute avec **Papermill** |
| **Talend** fait tous les traitements (bronze, silver, gold) | Compétence clé du poste visé. Talend est un outil ETL : ingestion, transformations, jointures et agrégations sont son cœur de métier |
| **Un notebook de contrôle par couche** | Séparer celui qui fait (Talend) de celui qui vérifie (notebook). Un contrôle indépendant détecte les erreurs du job. Airflow arrête la chaîne si un contrôle échoue |
| **Modèle en étoile** en gold, **SCD 2** en silver | Exigence de l'offre (SQL et modélisation). L'étoile est le modèle standard des entrepôts et de Power BI. SCD 2 garde chaque version d'un opérateur, ce qui rend l'axe « dynamique » possible |
| **Gouvernance** : rôles, RGPD, rétention, audit, dictionnaire | Mission explicite de l'offre. Les noms d'entrepreneurs individuels sont des données personnelles : ils ne sortent pas de silver |
| CI dès le début, CD à la fin | Chaque étape est protégée par des tests dès qu'elle existe. On ne déploie que ce qui marche en local |

---

## Étape 1 bis — Jeux de données (05/11/2026)

### Téléchargement

**Ce qui a été fait :** téléchargement de tous les jeux de données dans `data/raw/<source>/<version>/`.

**Pourquoi ce rangement :**
- **Un dossier par source :** on sait toujours d'où vient un fichier.
- **Un sous-dossier par version** (date ou millésime) : on garde l'historique et on peut comparer deux versions.
- `data/raw/` ne contient **que des fichiers tels que téléchargés**, jamais modifiés.
  C'est le même principe que la couche bronze.

| Source | Rôle |
|---|---|
| Agence Bio (annuaire, quotidien) | Table centrale : un opérateur par ligne |
| La Poste (codes postaux) | Code postal → commune |
| INSEE COG | Commune → département → région |
| INSEE populations | Densité pour 10 000 habitants |
| Agreste RA 2020 | Nombre total d'exploitations, pour calculer un taux de bio |
| Contours des départements | Cartes Power BI |
| SIRENE (échantillon) | Code NAF, taille, établissement actif ou fermé |

**Le cas de SIRENE :** le fichier complet pèse 2,9 Go. On n'en garde qu'un échantillon de 5 000 lignes
pour voir sa structure. Le pipeline lira le fichier complet en flux et ne gardera que nos ~87 000 SIRET.

### Doublon supprimé

L'ancien `data/raw/operateursbio.csv` a été supprimé, après avoir vérifié avec une **empreinte MD5**
qu'il était identique à la nouvelle copie.
Deux fichiers qui ont la même empreinte ont exactement le même contenu.

### Environnement Python (`.venv`)

**Ce qui a été fait :** création d'un environnement virtuel avec `python -m venv .venv`,
puis installation des paquets listés dans `requirements.txt`.

**Pourquoi :**
- Un **environnement virtuel** isole les paquets du projet de ceux du système.
  Deux projets peuvent ainsi utiliser des versions différentes de pandas sans conflit.
- `requirements.txt` fixe les **versions exactes** (`pandas==2.3.3`).
  N'importe qui, ou GitHub Actions, peut recréer exactement le même environnement avec `pip install -r requirements.txt`.

| Paquet | Rôle |
|---|---|
| pandas | Manipuler des tableaux de données |
| jupyterlab, ipykernel | Exécuter des notebooks (ipykernel est le « moteur » Python du notebook) |
| nbconvert | Exécuter un notebook en ligne de commande |
| papermill | Exécuter un notebook avec des paramètres. C'est ce qu'utilisera Airflow |

### `.gitignore`

**Pourquoi :** il liste les fichiers que Git ne doit jamais enregistrer.
- `data/` : les données sont volumineuses et se re-téléchargent. Un dépôt Git sert à versionner du code.
- `.venv/` : il se recrée à partir de `requirements.txt`.
- `.env` : il contiendra les mots de passe. Un secret ne doit jamais être publié sur GitHub.



**Ce qui a été fait :** transformation du fichier Agreste du format **long** au format **large**.

- **Format long :** une ligne par combinaison (département × taille × orientation × indicateur). Ce format est pratique à produire, mais peu lisible.
- **Format large :** une ligne par département, une colonne par indicateur. Ce format est pratique à joindre et à analyser.
- L'opération s'appelle un **pivot** (`DataFrame.pivot` dans pandas).

**Points techniques à savoir justifier :**
- **Lecture par morceaux** (`chunksize=500_000`) : le CSV fait 1,5 Go. On le lit par paquets de lignes
  et on ne garde que les départements, sans jamais le charger en entier en mémoire ni le décompresser sur le disque.
- **`dtype=str`** : sans ça, pandas transformerait le code département `01` en nombre `1`. On perdrait le zéro, et la Corse (`2A`) ferait planter la lecture.
- **Valeurs vides = secret statistique :** Agreste masque les chiffres qui permettraient d'identifier une exploitation.
- **Contrôle de cohérence :** le total obtenu (416 436 exploitations) correspond au chiffre publié par Agreste.
  Il faut toujours vérifier un résultat contre une référence connue.
- Le résultat va dans `data/interim/` : c'est un fichier de travail, pas une donnée brute.

---

## Étape 2 — PostgreSQL dans Docker (05/11/2026)

### 2a. Lancer PostgreSQL avec Docker Compose

**Fichiers :** `docker-compose.yml`, `.env` (secrets, ignoré par Git), `.env.example` (modèle publié).

**Notions à savoir expliquer :**
- **Image ou conteneur :** l'image est le modèle figé, en lecture seule (`postgres:17`). Le conteneur est une image en train de tourner, et il est jetable.
- **Volume :** stockage géré par Docker, hors du conteneur. Les données survivent à `docker compose down`.
  Seul `docker compose down -v` efface le volume.
- **Pourquoi un volume nommé** plutôt qu'un dossier du projet : le disque F: est en NTFS (Windows). PostgreSQL y aurait des problèmes de droits et de lenteur.
- **`/var/lib/postgresql/data`** : le chemin où l'image officielle range les données (variable `PGDATA`, définie dans son Dockerfile et documentée sur Docker Hub). Le côté droit d'un montage de volume doit être exactement ce chemin.
  Attention : il change à partir de PostgreSQL 18.
- **`127.0.0.1:5432:5432`** : port du PC → port du conteneur, accessible seulement depuis le PC.
- **Healthcheck** (`pg_isready`) : Docker sait si la base répond, pas seulement si le conteneur est lancé.
- **Réseau par défaut :** Compose crée un réseau privé par projet. Les conteneurs s'y joignent par leur nom de service.
- **`.env` / `.env.example`** : les secrets restent hors de Git, et le modèle montre quelles variables remplir.
- **Groupe `docker`** : l'accès au moteur Docker passe par `/var/run/docker.sock`, réservé au groupe `docker`.
  Un terminal ne lit ses groupes qu'à son ouverture, d'où le « permission denied » avant de le rouvrir. Il ne faut pas contourner avec `sudo`.

### 2b. Schémas et rôles

**Fichiers :** `sql/init/01_roles.sh`, `02_schemas.sql`, `03_privileges.sql`, montés sur `/docker-entrypoint-initdb.d`.

**Notions à savoir expliquer :**
- Les scripts de `/docker-entrypoint-initdb.d` ne s'exécutent **qu'à la création de la base**, quand le volume est vide.
  Pour les rejouer : `docker compose down -v`, puis `up -d`. Ils s'exécutent par ordre alphabétique, d'où les préfixes `01_`, `02_` et `03_`.
- **Rôles avec moindre privilège :** chaque outil n'a que les droits dont il a besoin.

| Rôle | Droits | Testé |
|---|---|---|
| `etl_writer` (Talend) | Propriétaire des schémas : crée et écrit | Crée et remplit une table ✔ |
| `bi_reader` (Power BI) | Lecture seule sur `gold` | Lit gold ✔ · ne peut pas créer ✘ · ne peut pas écrire ✘ · ne voit pas silver ✘ |
| `qa_reader` (notebooks) | Lecture sur les 4 couches, écriture dans `audit` | Lit silver ✔ |

- **`REVOKE ... FROM PUBLIC`** retire d'abord les droits donnés à tout le monde par défaut, puis on donne le strict nécessaire avec `GRANT`.
- **`ALTER DEFAULT PRIVILEGES`** donne à l'avance des droits sur les tables **futures** créées par `etl_writer`.
  Sans ça, il faudrait redonner les droits après chaque création de table par Talend.
- **Lire les droits** (`\dn+`) : `bi_reader=U/etl_writer` = USAGE, donné par etl_writer. `C` = CREATE.
- **Script `.sh` plutôt que `.sql`** pour les rôles : un fichier SQL ne lit pas les variables d'environnement. Les mots de passe restent dans `.env`.
- **`.gitattributes`** force les fins de ligne LF : un `.sh` en CRLF (format Windows) plante dans Linux.
- **Authentification ou autorisation :** dans le conteneur, les connexions locales ne demandent pas de mot de passe
  (l'authentification est en mode `trust`), mais les droits (l'autorisation) sont bien vérifiés. Depuis l'extérieur, le mot de passe est exigé.
- **Invites :** `$` = bash (Ubuntu), `=#` = psql prêt, `-#` = psql attend la fin d'une commande (`;`). Le pager affiche `(END)` : appuyer sur `q` pour en sortir.

---

## Étape 3 — Première CI GitHub Actions (05/11/2026)

**Fichiers :** `sql/tests/test_init.sql`, `.github/workflows/ci.yml`.

**Notions à savoir expliquer :**
- **CI (intégration continue)** : à chaque push, une machine neuve vérifie automatiquement que le projet fonctionne.
  Une erreur est détectée tout de suite, avant d'arriver sur `main` ou en production.
- **Vocabulaire GitHub Actions :**

| Terme | Sens |
|---|---|
| **Workflow** | Le fichier YAML dans `.github/workflows/`, qui décrit l'automatisation |
| **Événement** (`on:`) | Ce qui déclenche le workflow : push, pull request… |
| **Job** | Un ensemble d'étapes exécutées sur une même machine |
| **Step** | Une étape : une commande (`run:`) ou une action toute faite (`uses:`) |
| **Runner** | La machine louée par GitHub (`ubuntu-latest`), neuve à chaque exécution |
| **Action** | Une brique réutilisable, par exemple `actions/checkout`, qui récupère le code |

- **Parité des environnements :** la CI lance PostgreSQL avec **le même `docker-compose.yml`** qu'en local et que sur le VPS.
  On n'utilise pas les `services:` de GitHub Actions, qui démarrent la base avant la récupération du code : nos scripts `sql/init/` ne seraient pas exécutés.
- **Secrets en CI :** le vrai `.env` n'est pas sur GitHub. La CI fabrique un `.env` jetable, avec des mots de passe aléatoires (`openssl rand`).
- **`docker compose up --wait`** attend que le healthcheck passe à `healthy`.
- **Tests SQL :** blocs `DO $$ ... $$` avec `RAISE EXCEPTION`, et `ON_ERROR_STOP=1`. Une erreur arrête `psql`, qui renvoie un code d'échec, et la CI passe au rouge.
  Les fonctions `has_schema_privilege()` et `has_table_privilege()` interrogent les droits.
- **Test sans trace :** les tables de test sont créées dans une transaction annulée par `ROLLBACK`.
- **`if: failure()`** s'exécute seulement en cas d'échec (pour afficher les logs). **`if: always()`** s'exécute toujours (pour nettoyer).
- **Déclencheurs adaptés au flux `develop` → PR → `main`** : push sur `develop` et `main`, plus les pull requests vers `main`.
  **`concurrency`** annule une exécution devenue inutile quand on pousse deux fois de suite.

**Git :**
- **Commits atomiques :** un commit par sujet (configuration, documentation, exploration, base, CI). L'historique se lit comme un récit, et on peut annuler une partie précise.
- **Git sous Windows** pour ce dépôt, car le projet est sur un disque NTFS. Vus depuis Ubuntu, les fichiers appartiennent à `root` avec les droits `777`.
  Git y signale un « dubious ownership » (une protection de sécurité) et enregistrerait tous les fichiers comme exécutables.
- **Résultat :** CI verte sur `develop`.

---

## Étape 4 — Analyse des sources : l'annuaire bio (05/11/2026)

**Rangement des notebooks :** deux dossiers selon l'usage.
- `notebooks/exploration/` : comprendre une source, lancé à la main.
- `notebooks/qualite/` : contrôles par couche, exécutés chaque jour par Airflow.

Le notebook Agreste devient `exploration/02_...`, et le n°01 est l'annuaire, la source centrale.
La racine du projet est retrouvée en remontant jusqu'au dossier qui contient `docker-compose.yml`, ce qui fonctionne quel que soit l'emplacement du notebook.

**Notebook :** `notebooks/exploration/01_annuaire_bio.ipynb`

**Méthode, pour chaque colonne :** que contient-elle ? Quels défauts a-t-elle ? Quelle règle appliquer en silver ?

**Notions à savoir expliquer :**
- **Lire sans rien interpréter** (`dtype=str`, `keep_default_na=False`) : on voit ce que contient vraiment le fichier.
  C'est comme ça qu'on a découvert le texte `"None"` à la place de valeurs vides.
- **`repr()`** rend visibles les caractères cachés : un espace en fin de valeur, ou un caractère Unicode invisible (`\u202c`).
- **Clé de Luhn :** la somme de contrôle des SIRET, qui détecte les fautes de frappe. Exception : La Poste (SIREN `356000000`).
- **Grain d'une table :** ce que représente une ligne. Ici, une ligne est une **certification**, et non un opérateur.
  Un opérateur peut avoir deux lignes (deux organismes, deux dates…).
- **Clé naturelle ou clé technique :**
  - Une **clé naturelle** vient des données (le numéro bio).
  - Quand aucune combinaison de colonnes n'est unique, on crée une **clé technique** : ici, une empreinte (*hash*) de toute la ligne.
    Elle est stable d'un jour à l'autre, ce qui servira à détecter les changements pour l'historique SCD 2.
- **Première forme normale (1FN) :** une cellule contient une seule valeur. La colonne `ACTIVITES` (plusieurs valeurs) est donc éclatée en lignes (`tNormalize` dans Talend).
- **Encodages :** l'annuaire est en UTF-8, la base de La Poste en ISO-8859-1. Lire avec le mauvais encodage abîme les accents (`Ã©` au lieu de `é`).
- **Codes postaux :** espaces en trop, zéro initial perdu (passage par Excel), codes CEDEX absents de La Poste,
  Corse (`20` donne `2A` ou `2B`), outre-mer (départements sur 3 chiffres). Un code postal couvre souvent plusieurs communes.
- **RGPD :** la majorité des dénominations sont probablement des noms de personnes. Elles restent en silver, jamais en gold.

**Décisions** (détail dans la synthèse du notebook) : séparer opérateur, certification et activités ;
nettoyer plutôt que rejeter quand c'est sûr (`trim`, chiffres seuls, zéro initial) ;
garder la ligne mais tracer l'anomalie dans `audit.rejet` quand la valeur est douteuse (SIRET invalide, date future).

### Notebook `exploration/03_referentiel_geographique.ipynb`

**Objectif :** construire la chaîne code postal → commune → département → région, plus la population, les exploitations agricoles et les contours.

**Notions à savoir expliquer :**
- **Chaque source a ses habitudes de format :**
  - La Poste : `;`, ISO-8859-1, `#` devant l'en-tête ;
  - COG : `,`, UTF-8, valeurs entre guillemets ;
  - populations : `;`, UTF-8, fins de ligne CRLF.
  Chaque `tFileInputDelimited` de Talend aura son propre réglage.
- **Relation plusieurs à plusieurs :** un code postal couvre jusqu'à 46 communes, et une commune peut avoir jusqu'à 6 codes postaux.
- **Types de communes du COG** (`TYPECOM`) :
  - `COM` : commune de plein exercice ;
  - `COMD` : commune déléguée ;
  - `COMA` : commune associée ;
  - `ARM` : arrondissement municipal.
  On les ramène à leur commune parente (`COMPARENT`).
- **Piège d'unicité :** 584 codes sont partagés par une `COM` et une `COMD`, car une commune nouvelle garde le code de l'ancien chef-lieu.
  Le grain du fichier est le couple type × code, et non le code. Il faut donner la priorité à `COM`.
  Prendre « la première ligne trouvée » est une erreur silencieuse.
- **Population municipale (PMUN) ou totale (PTOT) :** PMUN est la référence statistique, car elle ne compte personne deux fois.
- **GeoJSON :** des formes géographiques en JSON (`Polygon`, `MultiPolygon` pour les îles).
- **Cohérence des clés entre sources :** on compare les listes de codes département de toutes les sources avant de joindre.
- **Règle de rattachement** d'un opérateur :
  1. Département unique via La Poste (99,1 % des cas).
  2. Sinon, déduction depuis le code postal : Corse `2A` / `2B`, outre-mer sur 3 chiffres, étranger (`99xxx` = code pays, `980xx` = Monaco).
  On trace la méthode utilisée.
- **Limites :** Mayotte absente des populations 2023, contours sans l'outre-mer.

### Notebook `exploration/04_sirene.ipynb`

**Notions à savoir expliquer :**
- **Biais d'échantillonnage :** les 5 000 premières lignes d'un fichier trié par SIREN sont les entreprises les plus anciennes (95 % fermées).
  On s'en sert pour la structure, jamais pour des proportions.
- **Statut de diffusion :** `P` = la personne s'est opposée à la diffusion, et ses données sont remplacées par `[ND]`.
  SIRENE applique déjà le RGPD. On ne reconstitue jamais une donnée masquée.
- **Minimisation (RGPD) :** sur 54 colonnes, on ne garde que celles utiles au cas d'usage.
- **Nomenclatures NAF :** un code n'a de sens qu'avec sa nomenclature. Les établissements actifs sont en NAF rév. 2, et la NAF 2025 arrive.
- **Tranche d'effectifs :** un code, et non un nombre. Il faut une table de correspondance.
- **Source qui fait foi (gouvernance) :**
  - SIRENE pour la localisation de l'établissement ;
  - l'annuaire pour les informations bio ;
  - les écarts sont comptés, et non corrigés à la main.
- **Ingestion en flux :** filtrer les ~87 000 SIRET de l'annuaire pendant la lecture (lookup en mémoire dans un `tMap`),
  puis supprimer le fichier complet (règle de rétention).

## Étape 5 — Modèle de données et dictionnaire (06/11/2026)

**Ce qui a été fait :** `docs/modele_donnees.md` (modèle conceptuel, logique et physique des quatre schémas)
et `docs/dictionnaire_donnees.md` (une fiche par table, une ligne par colonne).

**Pourquoi maintenant :** les jobs Talend écriront dans ces tables. Fixer le modèle avant d'écrire un job,
c'est éviter de refaire les jobs quand on découvre une erreur de grain.

**Notions à savoir expliquer :**
- **Trois niveaux de modèle :**
  - conceptuel : les objets du métier et leurs liens, sans technique ;
  - logique : tables, clés, relations, historique ;
  - physique : types PostgreSQL, contraintes, index.
- **Grain :** ce que représente une ligne. Celui de l'annuaire est la certification (opérateur × organisme), pas l'opérateur.
  Vérifié : 67 des 69 numéros bio en double ont deux certificateurs différents.
- **Clés :** naturelle (`numero_bio`), technique (`operateur_version_id`, générée), durable (`operateur_id`, stable pour toutes les versions), empreinte (MD5 pour détecter un changement).
- **SCD 2 :** fermer l'ancienne version et en ouvrir une nouvelle au lieu d'écraser.
  - Intervalle semi-ouvert `[date_debut, date_fin[` : deux versions ne se chevauchent jamais.
  - Requête *as of* : `date_debut <= D and (date_fin is null or date_fin > D)` reconstruit n'importe quel jour passé.
  - Trois cas : nouvelle clé, clé modifiée (hash différent), clé disparue (sortie).
  - `tPostgresqlSCD` gère les deux premiers ; les disparitions se détectent par anti-jointure dans un `tMap`.
  - Index unique partiel `where est_courant` : c'est la base qui garantit une seule version courante.
- **Rejeter le moins possible :** une valeur douteuse est mise à vide et qualifiée par une colonne `_statut`, la ligne reste comptée.
- **Modèle en étoile / constellation :** faits (ce qu'on compte) au centre, dimensions (axes d'analyse) autour.
  Deux faits qui partagent leurs dimensions = constellation.
  - Instantané périodique (`fait_operateur_activite`) : une photo par date.
  - Fait transactionnel (`fait_mouvement`) : un événement par ligne.
- **Dimension à rôles multiples :** `dim_date` sert à la fois de date de copie, d'engagement et de mouvement.
- **Membre « inconnu » (`-1`) :** un fait sans dimension ne disparaît pas dans une jointure.
- **Piège du comptage :** un opérateur à 3 activités a 3 lignes ; nombre d'opérateurs = `DISTINCTCOUNT`, pas `SUM`.
- **Pseudonymisation :** ni nom, ni SIRET, ni numéro bio en gold (le numéro bio permettrait de retrouver le nom dans l'annuaire public).
  `operateur_id` est un pseudonyme ; la correspondance reste en silver, inaccessible à Power BI.
- **Types :** les codes sont du texte (`01400`, `2A`), les ratios en `numeric` (calcul exact), les horodatages en `timestamptz`.

## Étape 6 — Premier job Talend : l'annuaire en bronze (06/11/2026)

### 6a. Le projet Talend dans Git

- Outil : **Talaxie Open Studio 8.9.0**, la version communautaire qui a pris la suite de Talend Open Studio (arrêté par Qlik en 2024).
- **Espace de travail** (dossier où Talend cherche les projets) déplacé dans `talend/` du dépôt. Les jobs sont des fichiers XML (`.item`), versionnables comme du code.
- On versionne ce qu'on crée, pas ce que l'outil génère : `.metadata`, `.JETEmitters`, `temp`, `poms` sont exclus par `.gitignore`.
- Après un déplacement, chercher les **chemins absolus** restants. Pour savoir quel dossier un outil utilise, regarder où il écrit.
- **Suppression logique :** la Corbeille de Talend marque `deleted="true"` sans effacer ; vider la Corbeille supprime vraiment.

### 6b. Les tables audit et bronze en SQL

- `sql/init/04_audit.sql` : `audit.execution`, `audit.rejet`, `audit.controle_qualite`.
- `sql/init/05_bronze.sql` : les 8 tables bronze, colonnes de source en `text` et 6 colonnes techniques.
- **`SET ROLE etl_writer`** : les scripts d'initialisation tournent en super-utilisateur. Sans ce changement de rôle, les tables appartiendraient à `bio_admin` et les droits automatiques (`DEFAULT PRIVILEGES FOR ROLE etl_writer`) ne s'appliqueraient pas.
- **Moindre privilège :** `qa_reader` n'écrit que dans `audit.controle_qualite` (`REVOKE INSERT` sur les deux autres tables d'audit).
- **Contraintes :** `CHECK` (valeurs autorisées, fin après début, date de fin obligatoire si le job est terminé), clé étrangère de chaque ligne bronze vers son exécution.
- `COMMENT ON` : la documentation vit aussi dans la base, visible depuis n'importe quel outil SQL.
- **Limite de `docker-entrypoint-initdb.d` :** exécuté seulement sur une base vide (`docker compose down -v` pour rejouer). En production : des migrations (Flyway, Liquibase).
- Tests ajoutés (6 à 9) : existence, propriétaire, commentaires, colonnes techniques, droits, contraintes. Un test de contrainte vérifie qu'une **insertion interdite est bien refusée**.

### 6c. Contexte et connexion dans Talend

- **Variable de contexte / environnement / groupe :** une variable (`pg_hote`), un jeu de valeurs (`local`, plus tard `vps`), un groupe partagé (`ctx_projet`) qu'on importe dans chaque job.
- **Connexion du Référentiel** (`cnx_postgres_bio`) en mode contexte : une seule définition, réutilisée par tous les composants.
- **Secrets :** le mot de passe n'est pas dans Git. Il est lu au démarrage par le **chargement implicite du contexte** depuis `talend/contexte_local.properties` (exclu de Git, modèle `.example` versionné).
- Trois chemins de fuite d'un secret : le code versionné, un chiffrement à clé connue (`enc:system.encryption.key.v1` = clé par défaut de Talend), les journaux (« Afficher les opérations »).
- **Caractères invisibles :** des tabulations collées au début des valeurs (`&#x9;` dans le XML). Toujours taper les valeurs de configuration.

### 6d. Le job `bronze_agence_bio`

- **Structure :** tPrejob (connexions, ouverture de l'audit, purge) → flux principal (lecture → tMap → écriture, puis commit et déclaration du succès) → tPostjob (fermeture de l'audit, rollback, fermeture des connexions). Le tPostjob s'exécute **toujours**, même après une erreur.
- **Composants `tDB…` génériques :** posés depuis la Palette, ils n'acceptent aucun lien tant que la base n'est pas choisie. Les créer en glissant la connexion du Référentiel.
- **Lecture CSV :** options CSV (guillemets doublés `""`), UTF-8, contrôle du nombre de champs, arrêt sur erreur. Un champ vide arrive en `''`, pas en `NULL`.
- **tMap :** une expression Java par colonne de sortie, appliquée ligne par ligne et en flux. Fait aussi jointures, filtres, rejets et plusieurs sorties.
- **Routine `Empreinte.md5` :** même résultat que `md5()` de PostgreSQL, car calculé sur les mêmes octets (UTF-8) avec un séparateur.
- **globalMap :** dictionnaire partagé par tout le job (l'`execution_id`, le statut, les compteurs `…_NB_LINE` de Talend). Les sous-jobs ne se passent pas de lignes.
- **Déclencheurs :** On Component Ok, On Subjob Ok (ordre d'exécution, sans données) ; lien Main (données).
- **Schéma alternatif :** avec une connexion existante, le schéma vient de la connexion ; le préciser dans les paramètres avancés du tDBOutput.
- **« Arrêter en cas d'erreur » :** décoché par défaut sur tDBOutput. Sans lui, le job finit avec un code de sortie 0 malgré l'erreur, et Airflow le croirait réussi.
- **Statut prudent :** `ECHEC` par défaut, `SUCCES` seulement après le commit.
- **Idempotence et atomicité :** relancer une date remplace ses lignes. La purge et l'insertion sont dans **une transaction** (connexion sans auto-commit, tDBCommit, tDBRollback), alors que l'audit a sa propre connexion en auto-commit pour survivre à un échec.
- Testé : réussite (88 143 lignes en 7 s, empreintes identiques à PostgreSQL), relance sans doublon, échec (fichier absent → `ECHEC`, bronze intact grâce au rollback).
- **Les séquences ne reculent jamais**, même après un `ROLLBACK` : des trous dans les identifiants sont normaux.

### 6e. Le job `bronze_insee` (07/11/2026)

- Job dupliqué de `bronze_agence_bio` : même prejob, même transaction, même postjob. Seuls les flux changent.
- **Trois flux dans un job** (départements, régions, populations), enchaînés par **On Subjob Ok** puis un seul commit : tout ou rien sur les 3 tables.
- **Millésimes en variables du job** (`millesime_cog = 2026`, `millesime_population = 2023`) ; `_date_copie` = 1er janvier du millésime, la même date pour la purge et l'écriture.
- **Formats différents :** COG en `,` avec guillemets et fin de ligne LF ; populations en `;` sans guillemets et en CRLF (séparateur de lignes `"\r\n"`, sinon un `\r` reste collé à la dernière colonne).
- **`Numeric.sequence` :** un compteur par nom pour toute la durée du job, donc un nom par flux.
- **Copier-coller de composants :** tout est copié, y compris ce qui devient faux (fichier, séquence, hash, table). Renommer un lien sortant d'un tMap crée une nouvelle sortie vide : ne pas le faire.
- **Compteurs additionnés en SQL avec `coalesce`** : après un échec, les compteurs des flux non exécutés valent `null` ; en Java, l'addition planterait dans le postjob.
- Testé : réussite (219 lignes en 0,8 s, empreintes identiques à PostgreSQL), relance sans doublon, échec du dernier flux (`ECHEC`, départements et régions annulés par le rollback).
- **Mayotte** est absente du fichier des populations 2023 : pas d'indicateur par habitant pour ce département.
- Limite : après un échec, `nb_lignes_ecrites` compte des lignes ensuite annulées par le rollback. Le statut `ECHEC` indique que rien n'est resté.

## Étape 7 — Simplification du périmètre (06/11/2026)

**Décision :** réduire le projet pour le terminer, sans perdre ce que l'offre demande.

- Sources : annuaire, départements et régions (COG), populations. **Écartées** : La Poste, SIRENE, recensement agricole (trop lourdes pour leur apport, restent des extensions possibles).
- Département déduit du **code postal** (règle Corse, outre-mer, étranger) au lieu de la commune.
- Axes : structure, marché, et développement par **date d'engagement**. Les sorties et changements de certificateur restent historisés en silver pour plus tard.
- Silver : SCD 2 sur la seule `certification` ; `operateur` en SCD 1 (état courant).
- Gold : **une étoile** (`fait_certification_activite` + 4 dimensions). Les indicateurs deviennent des mesures DAX dans Power BI.
- Un seul notebook de contrôle qualité. Le VPS devient optionnel.
- `sql/init/05_bronze.sql` : 4 tables bronze au lieu de 8 ; tables inutiles supprimées de la base locale sans la recréer (données gardées).

**À retenir :** limiter le périmètre (*scope*) est une décision de projet à part entière. Un livrable terminé, documenté et testé vaut mieux qu'un projet plus large inachevé.

## Étape 8 — Couche silver (07/11/2026)

### 8a. Les tables silver

- `sql/init/06_silver.sql` : 8 tables (référentiels, `operateur`, `certification`, `certification_activite`), toutes avec clé primaire.
- **Clés étrangères** entre tables : une région avant ses départements, un département avant ses populations et ses opérateurs.
- **`CHECK` de cohérence entre colonnes**, pas seulement de domaine : un SIRET n'est présent que si son statut vaut `VALIDE`, `est_courant` équivaut à `date_fin is null`, un membre spécial (`99`, `00`) n'a pas de région.
- **Index unique partiel** `where est_courant` : une seule version en cours par certification, garanti par la base.
- Test 10 : un jeu de lignes valides, puis des lignes interdites qui doivent être refusées, le tout annulé par `ROLLBACK`.

### 8b. Le job `silver_referentiels`

- Quatre flux enchaînés dans l'ordre des clés étrangères : régions → départements → populations → activités, un seul commit.
- **Lecture en SQL depuis bronze** (`tDBInput`) : dernière version avec `max(_date_copie)`, renommage avec `AS`, conversion de type (`pmun::integer`). Les membres spéciaux `99` et `00` sont ajoutés par `UNION ALL`, dans une CTE (`WITH`).
- **tMap** seulement pour une règle de gestion visible : `est_outre_mer = code_departement.length() == 3`.
- **tFixedFlowInput** pour les 8 activités et leur famille : des valeurs fixes, versionnées avec le job.
- **Insert or update** au lieu de purger : on ne peut pas supprimer un département auquel des opérateurs sont rattachés. La colonne cochée **Clé** dans le schéma sert à retrouver la ligne à mettre à jour.
- **Audit** : lignes écrites = insérées + mises à jour (229 à chaque exécution).
- **« Deviner le schéma »** échoue volontairement : le mot de passe n'est chargé qu'à l'exécution. Le schéma se saisit à la main.
- **Pièges rencontrés** : un Ctrl+C non pris en compte colle l'ancien presse-papiers (ici des composants d'un autre job) ; un sous-job sans déclencheur s'exécute hors de l'enchaînement et ses écritures sont perdues au rollback ; le contenu en ligne saisi sous Windows finit ses lignes par `\r\n`.
- Testé : premier chargement (insertions), relance (mises à jour, aucun doublon), échec du dernier flux (`ECHEC`, une valeur altérée dans silver reste altérée, preuve du rollback), puis rechargement normal qui corrige cette valeur à partir de bronze.
