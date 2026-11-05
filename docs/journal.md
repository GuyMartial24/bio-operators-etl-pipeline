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

### Notebook `01_agreste_ra2020_departements.ipynb`

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
- **Invites :** `$` = bash, `=#` = psql prêt, `-#` = psql attend la fin d'une commande (`;`). Le pager affiche `(END)` : appuyer sur `q` pour en sortir.
