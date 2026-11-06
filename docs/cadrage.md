# Cadrage — Observatoire territorial de la filière bio

## Contexte

L'Agence Bio publie chaque jour l'annuaire des opérateurs bio certifiés en France (~88 000 lignes).
Ce fichier dit **qui** est certifié, **où**, **depuis quand**, **pour quelles activités** et **par quel organisme**.
Pris tel quel, il ne répond à aucune question de pilotage. Ce projet le transforme en observatoire.

## Utilisateur cible

Un chargé de mission « alimentation et agriculture » d'une **Région** ou d'une **DRAAF**
(direction régionale de l'agriculture), qui pilote les projets alimentaires territoriaux (PAT)
et les aides à la structuration des filières bio.

## Question centrale

> **Où la filière bio est-elle déséquilibrée, comment s'est-elle développée, et qui la certifie ?**

### Axe 1 — Structure : les déserts de transformation

*Où produit-on du bio sans pouvoir le transformer ni le distribuer localement ?*

| Indicateur | Définition |
|---|---|
| Nb d'opérateurs par activité | Production, préparation, distribution… par département |
| Ratio de transformation | Nb de préparateurs / nb de producteurs |
| Ratio de distribution | Nb de distributeurs / nb de producteurs |
| Densité bio | Nb de producteurs pour 10 000 habitants |
| Indice de désert | Département avec beaucoup de producteurs (quartile haut) mais un ratio de transformation faible (quartile bas) |

### Axe 2 — Développement : les engagements dans le temps

*Depuis quand et où la filière s'est-elle développée ?*

| Indicateur | Définition |
|---|---|
| Engagements | Nb d'opérateurs par année d'engagement (historique depuis 1994) |
| Croissance | Évolution annuelle des engagements par département et par activité |

Les sorties et les changements de certificateur ne se voient qu'en comparant des copies successives du fichier.
L'historique SCD 2 de la couche silver les enregistre à partir de la première copie (05/11/2026) :
ils pourront être ajoutés au tableau de bord quand plusieurs mois de copies seront disponibles.

### Axe 3 — Marché : la certification

*Qui certifie la filière, et le marché est-il concentré ?*

| Indicateur | Définition |
|---|---|
| Part de marché | Nb d'opérateurs certifiés par organisme / total, par région |
| Concentration (HHI) | Somme des carrés des parts de marché (> 2 500 = marché très concentré) |
| Leader local | Organisme majoritaire par département |

## Sources de données

| Source | Usage | Fréquence |
|---|---|---|
| Annuaire des opérateurs bio (Agence Bio, data.gouv.fr) | Source principale | Quotidienne |
| Départements et régions (Code officiel géographique INSEE) | Libellés, région de chaque département | Annuelle |
| Populations légales INSEE par département | Densité | Annuelle |
| Contours des départements (GeoJSON) | Cartes dans Power BI | Ponctuelle |

Le département de chaque opérateur est **déduit de son code postal** (voir le modèle de données) :
c'est le niveau de tous les indicateurs.

### Sources écartées

L'exploration (`notebooks/exploration/`) a aussi étudié La Poste (code postal → commune), SIRENE (activité NAF, taille, établissement actif)
et le recensement agricole 2020 (exploitations par département). Elles ont été **écartées** pour garder un projet de taille raisonnable :

| Source | Raison |
|---|---|
| La Poste | Utile seulement au niveau commune ; au niveau département, la règle sur le code postal suffit |
| SIRENE | Fichier de plusieurs Go, mensuel, pour des informations hors des trois axes |
| Recensement agricole 2020 | Archive de 1,5 Go dans une archive, pour un seul indicateur (part des exploitations en bio) |

Elles restent des extensions possibles.

## Qualité des données (constats sur le fichier du 05/11/2026)

- 88 143 lignes, encodage UTF-8, séparateur `;`, guillemets CSV sur 77 lignes
- Grain : une ligne = une certification (opérateur × organisme), pas un opérateur : 69 numéros bio sur deux lignes
- SIRET : 701 vides, 75 `None` en texte, 1 caractère invisible, 11 clés de Luhn invalides
- 1 322 dates d'engagement à `None`, toutes chez les « Dispense de certification » ; 6 dates dans le futur
- Codes postaux : espaces en fin de valeur, un zéro de tête perdu
- Colonne `ACTIVITES` multi-valuée (`Production,Préparation,…`), à éclater
- ~77 % des dénominations contiennent probablement un nom de personne (RGPD)

## Organisation des données : architecture en médaillon

| Couche | Contenu | Règles |
|---|---|---|
| **Bronze** | Données brutes, telles que reçues | Aucune transformation, tout en texte, plus 6 colonnes techniques. Relancer une copie la remplace (idempotence) |
| **Silver** | Données nettoyées, typées et modélisées : opérateurs, certifications, activités, référentiels | Valeurs douteuses qualifiées, activités éclatées, département déduit, historique SCD 2 des certifications, rejets tracés |
| **Gold** | Modèle en étoile prêt pour Power BI | Une table de faits et 4 dimensions, sans donnée personnelle. Les indicateurs sont calculés dans Power BI |

Flux : `fichiers sources → bronze → silver → gold → Power BI`

**Talend fait tous les traitements. Un notebook contrôle le résultat.**

| Couche | Job Talend | Contrôle (notebook `qualite/controle_qualite.ipynb`) |
|---|---|---|
| Bronze | `bronze_agence_bio`, `bronze_insee` | Nombre de lignes, fraîcheur, empreintes |
| Silver | `silver_referentiels`, `silver_annuaire` | Clés uniques, une seule version courante, part des départements inconnus, rejets |
| Gold | `gold_etoile` | Totaux cohérents avec silver, aucune clé orpheline |

**Airflow** enchaîne chaque jour : jobs bronze → jobs silver → job gold → contrôle qualité.
Si un job ou un contrôle échoue, la chaîne s'arrête et Power BI garde les dernières données valides.

Les notebooks sont rangés par usage : `notebooks/exploration/` (comprendre les sources, lancés à la main)
et `notebooks/qualite/` (contrôle, exécuté par Airflow avec Papermill).

## Modélisation des données

| Couche | Modèle | Pourquoi |
|---|---|---|
| Silver | Modèle relationnel normalisé, avec **historique SCD de type 2** sur les certifications | Chaque changement d'une certification (activités, date) ou sa disparition crée une version datée (`date_debut`, `date_fin`, `est_courant`). C'est la base des futurs indicateurs de sorties et de changements de certificateur |
| Gold | **Modèle en étoile** | Le modèle de référence des entrepôts de données et de Power BI : requêtes simples, filtres rapides |

Étoile de la couche gold :

- **Fait** `fait_certification_activite` : une ligne par certification en cours × activité
- **Dimensions** : `dim_departement` (département, région, population), `dim_activite`, `dim_certificateur`, `dim_date` (date d'engagement)

Détails : `docs/modele_donnees.md` et `docs/dictionnaire_donnees.md`.

## Gouvernance des données

| Thème | Mise en œuvre |
|---|---|
| **Responsabilités** | Un propriétaire par table (fiche dans le dictionnaire de données) |
| **Sécurité** | Rôles PostgreSQL séparés : `etl_writer` (Talend, écriture), `bi_reader` (Power BI, lecture seule sur gold), `qa_reader` (notebook de contrôle, lecture). Mots de passe hors du code (`.env`, `talend/contexte_local.properties`, secrets GitHub) |
| **Données personnelles (RGPD)** | Les noms d'entrepreneurs individuels restent en silver, accès restreint. Gold et Power BI n'ont ni nom, ni SIRET, ni numéro bio |
| **Rétention** | Règles par table (voir *Gestion du stockage*) |
| **Audit** | `audit.execution` (chaque job : statut, lignes lues et écrites), `audit.rejet` (lignes refusées et motif), `audit.controle_qualite` (résultats des contrôles) |
| **Documentation** | Dictionnaire de données, commentaires SQL dans la base (`COMMENT ON`) |

## Gestion du stockage

| Donnée | Volume | Règle de conservation |
|---|---|---|
| Annuaire bio (quotidien) | 8,5 Mo / jour | Fichier archivé compressé. En base, bronze garde les 30 dernières copies (~600 Mo) |
| Référentiels INSEE | < 1 Mo | Une version par millésime |
| Silver | Quelques dizaines de Mo / an | Historique : seules les modifications sont enregistrées |
| Gold | Quelques Mo | Recalculé à chaque exécution |
| Audit | Faible | 2 ans ; `audit.rejet` 90 jours (peut contenir des noms) |

## Livrable final : tableau de bord Power BI

1. **Vue d'ensemble** : chiffres clés, carte des opérateurs par département, engagements par année
2. **Déserts de transformation** : carte de l'indice de désert, ratios par département
3. **Marché de la certification** : parts de marché, HHI par région, leaders locaux

## Rôle de chaque technologie

| Techno | Rôle dans le projet |
|---|---|
| **Talend** | Moteur ETL des trois couches : ingestion, nettoyage, historique SCD 2, étoile, audit, transactions. Compétence clé du poste visé |
| **PostgreSQL** | Schémas `bronze`, `silver`, `gold`, `audit`, rôles séparés, contraintes et commentaires |
| **Notebook Jupyter** | Contrôle qualité des trois couches, exécuté par Airflow avec Papermill ; notebooks d'exploration |
| **Airflow** | Orchestration quotidienne : télécharger l'annuaire → jobs Talend → contrôle qualité |
| **Docker** | PostgreSQL, Airflow et les jobs Talend dans des conteneurs, identiques en local et sur un serveur |
| **Power BI Desktop** | Tableau de bord des trois axes, indicateurs en DAX |
| **GitHub Actions** | CI : tests de la base, des DAG et du notebook. Déploiement sur le VPS en option |
