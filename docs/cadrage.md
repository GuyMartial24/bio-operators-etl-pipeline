# Cadrage — Observatoire territorial de la filière bio

## Contexte

L'Agence Bio publie chaque jour l'annuaire des opérateurs bio certifiés en France (~88 000 opérateurs).
Ce fichier dit **qui** est certifié, **où**, **depuis quand**, **pour quelles activités** et **par quel organisme**.
Pris tel quel, il ne répond à aucune question de pilotage. Ce projet le transforme en observatoire.

## Utilisateur cible

Un chargé de mission « alimentation et agriculture » d'une **Région** ou d'une **DRAAF**
(direction régionale de l'agriculture), qui pilote les projets alimentaires territoriaux (PAT)
et les aides à la structuration des filières bio.

## Question centrale

> **Où la filière bio est-elle déséquilibrée, comment évolue-t-elle, et qui la certifie ?**

Elle se découpe en trois axes, qui forment un seul observatoire.

### Axe 1 — Structure : les déserts de transformation

*Où produit-on du bio sans pouvoir le transformer ni le distribuer localement ?*

| Indicateur | Définition |
|---|---|
| Nb d'opérateurs par activité | Production, préparation, distribution, stockage… par département |
| Ratio de transformation | Nb de préparateurs / nb de producteurs |
| Ratio de distribution | Nb de distributeurs / nb de producteurs |
| Densité bio | Nb de producteurs pour 10 000 habitants |
| Indice de désert | Département avec beaucoup de producteurs (quartile haut) mais un ratio de transformation faible (quartile bas) |

### Axe 2 — Dynamique : la filière dans le temps

*La filière grandit-elle, où, et qui la quitte ?*

| Indicateur | Définition |
|---|---|
| Nouveaux engagés | Nb d'opérateurs par année ou mois d'engagement (historique depuis 1994) |
| Croissance | Évolution annuelle des engagements par département et par activité |
| Sorties | Opérateurs présents dans une copie du fichier et absents de la suivante |
| Solde net | Entrées − sorties sur la période |

Limite : le fichier ne contient que les opérateurs **actuellement** certifiés.
Les entrées passées se déduisent de la date d'engagement, mais les **sorties** ne sont visibles
qu'à partir du moment où Airflow conserve une copie quotidienne du fichier.

### Axe 3 — Marché : la certification

*Qui certifie la filière, et le marché est-il concentré ?*

| Indicateur | Définition |
|---|---|
| Part de marché | Nb d'opérateurs certifiés par organisme / total, par région |
| Concentration (HHI) | Somme des carrés des parts de marché (> 2 500 = marché très concentré) |
| Leader local | Organisme majoritaire par département |
| Changements de certificateur | Opérateurs qui changent d'organisme entre deux copies (lien avec l'axe 2) |

## Sources de données

| Source | Usage | Fréquence |
|---|---|---|
| Annuaire des opérateurs bio (Agence Bio, data.gouv.fr) | Source principale | Quotidienne |
| Base officielle des codes postaux (La Poste, data.gouv.fr) | Code postal → commune → département | Ponctuelle |
| Référentiel géographique INSEE (communes, départements, régions) | Hiérarchie géographique | Annuelle |
| Population légale INSEE par département | Calcul de densité | Annuelle |
| Recensement agricole 2020 (Agreste) — exploitations par département | Taux de bio (exploitations bio / total) | Ponctuelle |
| Contours des départements (GeoJSON / TopoJSON) | Cartes colorées dans Power BI | Ponctuelle |
| Base SIRENE (INSEE), filtrée sur les SIRET de l'annuaire | Code NAF, taille, établissement actif ou fermé | Mensuelle |

### Enrichissement du fichier de base

L'annuaire reste la table centrale (une ligne par opérateur). Les autres jeux s'y rattachent par jointure.

| Jeu de données | Clé de jointure | Niveau | Couche |
|---|---|---|---|
| Codes postaux (La Poste) | code postal → code commune INSEE | Opérateur | Silver |
| Code officiel géographique (INSEE) | code commune → département → région | Opérateur | Silver |
| SIRENE (INSEE) | SIRET | Opérateur | Silver |
| Populations légales (INSEE) | code département | Département | Gold |
| Recensement agricole 2020 (Agreste) | code département | Département | Gold |
| Contours des départements | code département | Département | Power BI |

Les 701 opérateurs sans SIRET ne peuvent pas être enrichis par SIRENE. Leur nombre est suivi par les contrôles de qualité.

Points d'attention : un code postal peut couvrir plusieurs communes, et ses deux premiers chiffres
ne donnent pas toujours le département (Corse 2A/2B, outre-mer 97x, CEDEX).

## Qualité des données (constats initiaux sur le fichier du 05/11/2026)

- 88 143 lignes, encodage UTF-8, séparateur `;`
- 701 SIRET vides, ~1 000 SIRET en doublon
- 1 322 dates d'engagement à `None`, toutes chez les « Dispense de certification »
- 5 dates d'engagement en 2027 (dans le futur)
- Colonne `ACTIVITES` multi-valuée (`Production,Préparation,…`), à éclater

## Organisation des données : architecture en médaillon

Les données traversent trois couches, chacune dans son propre schéma PostgreSQL.

| Couche | Contenu | Règles |
|---|---|---|
| **Bronze** | Données brutes, telles que reçues : chaque copie quotidienne de l'annuaire et chaque référentiel | Aucune transformation. Tout en texte, plus la date de chargement et le nom du fichier source. On ne supprime jamais rien, ce qui permet de tout rejouer |
| **Silver** | Données nettoyées, typées et modélisées : opérateurs, activités, certificateurs, géographie | Doublons traités, dates et SIRET contrôlés, activités éclatées, codes postaux reliés aux communes. Historique des opérateurs (entrées, sorties, changements de certificateur). Lignes invalides placées dans une table de rejets |
| **Gold** | Indicateurs prêts à l'emploi pour Power BI, un jeu de tables par axe | Agrégats par département et région : ratios et indice de désert (axe 1), entrées, sorties et solde (axe 2), parts de marché et HHI (axe 3) |

Flux : `fichiers sources → bronze → silver → gold → Power BI`

**Talend fait tous les traitements. Un notebook par couche contrôle le résultat.**

| Couche | Talend (traitement) | Notebook (contrôle qualité) |
|---|---|---|
| Bronze | Téléchargement et chargement des sources telles quelles | `qualite/01_bronze.ipynb` : fichiers reçus, nombre de lignes, colonnes, encodage, fraîcheur |
| Silver | Nettoyage, dédoublonnage, éclatement des activités, jointures géographiques et SIRENE, historique, rejets | `qualite/02_silver.ipynb` : clés uniques, taux de jointure, volume des rejets |
| Gold | Calcul des indicateurs des trois axes | `qualite/03_gold.ipynb` : totaux cohérents, ratios plausibles, écart avec la veille |

**Airflow** enchaîne : job bronze → contrôle bronze → job silver → contrôle silver → job gold → contrôle gold.
Si un contrôle échoue, la chaîne s'arrête et Power BI garde les dernières données valides.

Les notebooks sont rangés par usage : `notebooks/exploration/` (un notebook par source, pour comprendre les données avant de construire les jobs Talend, lancés à la main) et `notebooks/qualite/` (contrôles par couche, exécutés chaque jour par Airflow).

## Modélisation des données

| Couche | Modèle | Pourquoi |
|---|---|---|
| Silver | Modèle relationnel normalisé, avec **historique SCD de type 2** sur les opérateurs | SCD 2 (*Slowly Changing Dimension*) : chaque changement d'un opérateur (certificateur, activités) crée une nouvelle version datée (`date_debut`, `date_fin`, `est_courant`). C'est ce qui permet de mesurer les entrées, les sorties et les changements de certificateur |
| Gold | **Modèle en étoile** : une table de faits au centre, reliée à des tables de dimensions | Le modèle de référence des entrepôts de données et de Power BI : requêtes simples et rapides, indicateurs faciles à filtrer |

Modèle en étoile de la couche gold :

- **Fait** `fait_operateur_activite` : une ligne par opérateur × activité, à une date de copie
- **Dimensions** : `dim_geographie` (commune → département → région, population, exploitations RA 2020),
  `dim_activite`, `dim_certificateur`, `dim_date`, `dim_operateur` (sans données personnelles)
- **Tables d'indicateurs** des trois axes, calculées à partir de l'étoile

Les schémas du modèle (conceptuel, logique, physique) sont documentés dans `docs/modele_donnees.md`.

## Gouvernance des données

| Thème | Mise en œuvre |
|---|---|
| **Responsabilités** | Un propriétaire par couche et par table (fiche dans le dictionnaire de données) |
| **Sécurité** | Rôles PostgreSQL séparés : `etl_writer` (Talend, écriture), `bi_reader` (Power BI, lecture seule sur gold), `qa_reader` (notebooks de contrôle, lecture). Mots de passe hors du code (fichier `.env`, secrets GitHub) |
| **Données personnelles (RGPD)** | L'annuaire contient des noms d'entrepreneurs individuels. Ils restent en silver, avec un accès restreint, et ne sont jamais exposés en gold ni dans Power BI |
| **Rétention** | Règles de conservation par donnée (voir *Gestion du stockage*), appliquées par un DAG de maintenance |
| **Audit** | Table `audit.execution` alimentée par chaque job Talend : job, date, lignes lues, écrites et rejetées, durée, statut. Table `audit.rejet` pour les lignes rejetées et leur motif |
| **Qualité** | Un notebook de contrôle par couche. Les résultats sont enregistrés dans `audit.controle_qualite` |
| **Documentation** | Dictionnaire de données (`docs/dictionnaire_donnees.md`) : description, type, source et règle de calcul de chaque table et colonne |

## Gestion du stockage (VPS, 200 Go)

| Donnée | Volume brut | Règle de conservation |
|---|---|---|
| Annuaire bio (quotidien) | 8,5 Mo / jour, soit ~3 Go / an | Fichier archivé compressé (~0,7 Go / an). En base, bronze ne garde que les 30 derniers chargements |
| SIRENE (mensuel) | 2,9 Go par fichier | Lu en flux et filtré sur les SIRET de l'annuaire (~25 Mo gardés). Le fichier complet n'est jamais conservé |
| Référentiels (La Poste, INSEE, contours) | < 20 Mo | Une version par millésime |
| Silver | Quelques centaines de Mo / an | Historique : seules les modifications sont enregistrées |
| Gold | Quelques Mo | Recalculé à chaque exécution |
| Sauvegardes PostgreSQL | Quelques Go | 7 quotidiennes + 4 hebdomadaires |
| Images Docker et logs Airflow | 3 à 5 Go | Purge automatique des logs de plus de 30 jours |

Estimation après un an : 15 à 20 Go. Un DAG Airflow de maintenance applique ces règles
et alerte si le disque dépasse 80 %. En local, on ne travaille qu'avec quelques jours de données.

## Livrable final : tableau de bord Power BI

1. **Vue d'ensemble** : chiffres clés, carte de France des opérateurs
2. **Déserts de transformation** : carte de l'indice de désert, ratios par département
3. **Dynamique** : courbes d'engagements, entrées et sorties, solde net
4. **Marché de la certification** : parts de marché, HHI, leaders locaux, changements de certificateur

## Rôle de chaque technologie

| Techno | Rôle dans le projet |
|---|---|
| **Talend** | Moteur ETL des trois couches : ingestion (bronze), nettoyage, jointures et historique (silver), indicateurs (gold), rejets. Compétence clé du poste visé |
| **Notebooks Jupyter** | Un notebook de contrôle qualité par couche, exécuté par Airflow avec Papermill, plus des notebooks d'exploration |
| **PostgreSQL** | Schémas `bronze` (brut), `silver` (nettoyé, historisé en SCD 2), `gold` (modèle en étoile et indicateurs pour Power BI), `audit` (exécutions, rejets, contrôles qualité). Rôles séparés pour la sécurité |
| **Airflow** | Orchestration quotidienne : télécharger → archiver la copie → lancer Talend → calculer les indicateurs → contrôler la qualité |
| **Docker** | PostgreSQL, Airflow et les jobs Talend dans des conteneurs, identiques en local et sur le VPS |
| **Power BI Desktop** | Tableau de bord des trois axes |
| **GitHub Actions** | CI : tests SQL, DAG Airflow et qualité des données. CD : construction des images et déploiement sur le VPS |
