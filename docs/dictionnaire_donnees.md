# Dictionnaire de données — Observatoire territorial de la filière bio

Le dictionnaire décrit **chaque table et chaque colonne** : ce qu'elle contient, d'où elle vient, comment elle est calculée.
Les choix de modélisation sont justifiés dans le [modèle de données](modele_donnees.md).

## Comment lire ce document

Chaque table a une **fiche** :

| Rubrique | Contenu |
|---|---|
| **Grain** | Ce que représente une ligne |
| **Alimentation** | Le job Talend (ou le notebook) qui écrit la table, et sa fréquence |
| **Propriétaire** | Qui répond de la table. Ici, un seul data engineer tient les deux rôles : métier (le sens des données) et technique (le job) |
| **Rétention** | Combien de temps les lignes sont gardées |
| **Sensibilité** | `Publique` (donnée ouverte), `Interne` (dérivée, sans donnée personnelle), `Personnelle` (RGPD) |
| **Accès** | Rôles PostgreSQL qui peuvent lire la table |

Colonnes des tableaux : **Null** = `non` si la valeur est obligatoire.

---

## Schéma `bronze`

**Règles communes :** toutes les colonnes de source sont en `text`, nommées comme dans le fichier d'origine (en *snake_case*), sans aucune transformation.
Propriétaire : data engineer. Accès : `etl_writer`, `qa_reader`.

### Colonnes techniques, présentes dans toutes les tables bronze

| Colonne | Type | Null | Description |
|---|---|---|---|
| `_execution_id` | `bigint` | non | Exécution qui a chargé la ligne (`audit.execution`) |
| `_date_copie` | `date` | non | Date de la version de la source |
| `_fichier_source` | `text` | non | Nom du fichier lu |
| `_numero_ligne` | `integer` | non | Numéro de la ligne dans le fichier (hors en-tête) |
| `_hash_ligne` | `char(32)` | non | MD5 de la ligne brute |
| `_date_chargement` | `timestamptz` | non | Horodatage de l'écriture |

### Tables bronze

| Table | Grain | Alimentation | Rétention | Sensibilité |
|---|---|---|---|---|
| `agence_bio_operateur` | Une ligne de l'annuaire, pour une copie | `bronze_agence_bio`, quotidien | 30 dernières copies | **Personnelle** (`denomination`) |
| `laposte_code_postal` | Un couple code postal × commune × libellé d'acheminement | `bronze_referentiels`, à la demande | Dernière version | Publique |
| `insee_cog_commune` | Un couple type × code commune | `bronze_referentiels`, annuel | Une version par millésime | Publique |
| `insee_cog_departement` | Un département | `bronze_referentiels`, annuel | Une version par millésime | Publique |
| `insee_cog_region` | Une région | `bronze_referentiels`, annuel | Une version par millésime | Publique |
| `insee_population_departement` | Un département | `bronze_referentiels`, annuel | Une version par millésime | Publique |
| `agreste_ra2020` | Un département × une modalité de chaque dimension × un indicateur | `bronze_agreste`, unique | Définitive | Publique |
| `sirene_etablissement` | Un établissement SIRENE dont le SIRET est dans l'annuaire | `bronze_sirene`, mensuel | 3 derniers stocks | Publique (les données des personnes opposées sont déjà `[ND]`) |

Colonnes de source de `agence_bio_operateur` :

| Colonne | Colonne d'origine | Exemple | Remarques de l'exploration |
|---|---|---|---|
| `siret` | `SIRET` | `38459550000024` | 701 vides, 75 `None` en texte, 1 caractère invisible, 11 clés de Luhn invalides |
| `numero_bio` | `NUMERO BIO` | `1` | 69 valeurs présentes deux fois |
| `denomination` | `DENOMINATION` | `LES PAPILLONS DU LARRY` | ~77 % contiennent probablement un nom de personne |
| `code_postal_siege_social` | `CODE POSTAL SIEGE SOCIAL` | `51120` | Espaces finaux, un zéro de tête perdu, ~420 CEDEX |
| `dateengagement` | `DATEENGAGEMENT` | `2020-07-08` | 1 322 `None` (dispenses), 6 dates futures |
| `activites` | `ACTIVITES` | `Production,Préparation` | 1 à 6 valeurs parmi 8 |
| `organisme_certificateur` | `ORGANISME CERTIFICATEUR` | `Ecocert France` | 10 valeurs, dont « Dispense de certification » |

Les colonnes des autres tables bronze sont listées dans le [modèle de données, § 3.2](modele_donnees.md#32-bronze--la-copie-fidèle-des-sources).

---

## Schéma `silver`

Propriétaire : data engineer. Accès : `etl_writer`, `qa_reader`. **Aucun accès pour `bi_reader`.**

### `silver.ref_region`

Grain : une région. Alimentation : `silver_referentiels`, annuel. Rétention : millésime courant. Sensibilité : publique.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `code_region` | `text` PK | non | Code INSEE de la région (`84`) | COG `REG` |
| `region_libelle` | `text` | non | Nom avec article et accents (`Auvergne-Rhône-Alpes`) | COG `LIBELLE` |
| `millesime_cog` | `smallint` | non | Année du COG | Nom du fichier |

### `silver.ref_departement`

Grain : un département, plus deux membres spéciaux. Alimentation : `silver_referentiels`, annuel. Sensibilité : publique.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `code_departement` | `text` PK | non | `01`…`95`, `2A`, `2B`, `971`…`976`. Membres spéciaux : `99` étranger, `00` inconnu | COG `DEP` |
| `departement_libelle` | `text` | non | Nom du département | COG `LIBELLE` |
| `code_region` | `text` FK | oui | Région (vide pour `99` et `00`) | COG `REG` |
| `est_outre_mer` | `boolean` | non | `true` pour les codes à 3 chiffres | Règle : longueur du code = 3 |
| `millesime_cog` | `smallint` | non | Année du COG | Nom du fichier |

### `silver.ref_commune`

Grain : une commune de plein exercice ou un arrondissement municipal. Sensibilité : publique.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `code_commune` | `text` PK | non | Code INSEE sur 5 caractères (`01001`, `2A004`) | COG `COM`, **priorité au type `COM`** quand le code est partagé avec une `COMD` (584 cas) |
| `commune_libelle` | `text` | non | Nom de la commune | COG `LIBELLE` |
| `type_commune` | `text` | non | `COM` ou `ARM` | COG `TYPECOM` |
| `code_departement` | `text` FK | non | Département | COG `DEP` |
| `millesime_cog` | `smallint` | non | Année du COG | Nom du fichier |

### `silver.ref_code_postal_commune`

Grain : un couple code postal × commune (table d'association plusieurs à plusieurs). Sensibilité : publique.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `code_postal` | `text` PK | non | 5 chiffres | La Poste `Code_postal` |
| `code_commune` | `text` PK, FK | non | Commune desservie | La Poste `Code_commune_INSEE`, ramené à la commune parente si c'est une commune déléguée |
| `date_version` | `date` | non | Date du fichier La Poste | Dossier de téléchargement |

Plusieurs libellés d'acheminement pour un même couple sont fusionnés en une ligne.

### `silver.ref_activite`

Grain : une activité. Alimentation : initialisée à la main (8 valeurs), contrôlée à chaque chargement. Sensibilité : publique.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `activite_code` | `text` PK | non | Code en majuscules sans accent (`PREPARATION`) | Dérivé du libellé |
| `activite_libelle` | `text` | non | Libellé tel que dans l'annuaire (`Préparation`) | Annuaire |
| `famille` | `text` | non | `production`, `transformation`, `distribution`, `logistique`, `echanges` | Règle métier, voir le modèle § 3.3 |

### `silver.ref_certificateur`

Grain : un organisme certificateur. Sensibilité : publique.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `certificateur_id` | `integer` PK identity | non | Clé technique | Générée |
| `certificateur_libelle` | `text` unique | non | Nom tel que dans l'annuaire | Annuaire |
| `est_dispense` | `boolean` | non | `true` pour « Dispense de certification » | Règle : libellé exact |
| `date_premiere_observation` | `date` | non | Première copie où l'organisme apparaît | Date de copie |

### `silver.ref_tranche_effectif`

Grain : une tranche d'effectifs SIRENE. Alimentation : à la main, depuis la documentation INSEE. Sensibilité : publique.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `tranche_code` | `text` PK | non | `NN`, `00`, `01`, `02`, `03`, `11`, `12`… `53` | INSEE |
| `tranche_libelle` | `text` | non | `1 ou 2 salariés`, `20 à 49 salariés`… | INSEE |
| `effectif_min` | `integer` | oui | Borne basse (vide pour `NN`) | INSEE |
| `effectif_max` | `integer` | oui | Borne haute (vide pour la dernière tranche) | INSEE |

### `silver.population_departement`

Grain : un département × une année. Sensibilité : publique.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `code_departement` | `text` PK, FK | non | Département | INSEE `DEP` |
| `annee` | `smallint` PK | non | Année de référence (`2023`) | Millésime du fichier |
| `population_municipale` | `integer` | non | Population municipale | INSEE `PMUN`. Mayotte absente du millésime 2023 |
| `population_totale` | `integer` | non | Population totale (pour information) | INSEE `PTOT` |

### `silver.exploitation_departement`

Grain : un département × une année de recensement. Alimentation : `silver_agreste` (pivot). Sensibilité : publique.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `code_departement` | `text` PK, FK | non | Département | Agreste `CODE_GEO` |
| `annee` | `smallint` PK | non | `2020` | Agreste `ANNREF` |
| `nb_exploitations` | `integer` | non | Nombre d'exploitations, toutes orientations | `VALEUR_EXTRAPOLEE`, modalité « Ensemble » |
| `sau_ha` | `numeric(12,2)` | oui | Surface agricole utile, en hectares | Idem, indicateur SAU |
| `etp` | `numeric(12,2)` | oui | Travail en équivalents temps plein | Idem, indicateur ETP |
| `pbs_keur` | `numeric(14,2)` | oui | Production brute standard, en milliers d'euros | Idem, indicateur PBS |
| `nb_expl_<otex>` | `integer` | oui | Exploitations par orientation (10 colonnes : `bovins_lait`, `grandes_cultures`, `viticulture`…) | Pivot sur la dimension OTEX |

Contrôle : la somme nationale vaut 416 436 exploitations (chiffre publié par Agreste).

### `silver.etablissement_sirene`

Grain : un établissement (SIRET), dernier stock mensuel. Alimentation : `silver_sirene`, mensuel. Rétention : dernier stock. Sensibilité : publique.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `siret` | `char(14)` PK | non | Identifiant de l'établissement | SIRENE `siret` |
| `siren` | `char(9)` | non | Identifiant de l'entreprise | SIRENE `siren` |
| `statut_diffusion` | `text` | non | `O` diffusible, `P` partiellement diffusible | SIRENE `statutDiffusionEtablissement` |
| `est_actif` | `boolean` | non | `true` si état `A` | SIRENE `etatAdministratifEtablissement` |
| `date_debut_etat` | `date` | oui | Date du dernier changement d'état | SIRENE `dateDebut` |
| `date_creation` | `date` | oui | Création de l'établissement | SIRENE `dateCreationEtablissement` |
| `est_siege` | `boolean` | non | Siège de l'entreprise | SIRENE `etablissementSiege` |
| `code_naf` | `text` | oui | Activité principale (`10.71C`) | SIRENE `activitePrincipaleEtablissement` |
| `nomenclature_naf` | `text` | oui | `NAFv2` pour les actifs | SIRENE `nomenclatureActivitePrincipaleEtablissement` |
| `code_naf25` | `text` | oui | Activité en NAF 2025 | SIRENE `activitePrincipaleNAF25Etablissement` |
| `tranche_code` | `text` FK | oui | Tranche d'effectifs | SIRENE `trancheEffectifsEtablissement` |
| `annee_effectif` | `smallint` | oui | Année de la tranche | SIRENE `anneeEffectifsEtablissement` |
| `est_employeur` | `boolean` | oui | Caractère employeur | SIRENE `caractereEmployeurEtablissement` |
| `code_commune` | `text` FK | oui | Commune exacte de l'établissement | SIRENE `codeCommuneEtablissement` |
| `code_postal` | `text` | oui | Code postal | SIRENE `codePostalEtablissement`. `[ND]` → vide |
| `lambert93_x`, `lambert93_y` | `numeric(10,2)` | oui | Coordonnées en mètres | SIRENE `coordonneeLambert…`. `[ND]` → vide |
| `date_stock` | `date` | non | Mois du stock | Nom du fichier |

### `silver.operateur` (SCD 2)

Grain : une version d'un opérateur. Alimentation : `silver_annuaire`, quotidien. Rétention : illimitée (l'historique est l'objet de l'axe 2).
**Sensibilité : personnelle** (`denomination`, `siret` d'entrepreneurs individuels).

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `operateur_version_id` | `bigint` PK identity | non | Clé technique de la version | Générée |
| `operateur_id` | `integer` | non | **Clé durable** : identique pour toutes les versions d'un numéro bio | Attribuée au premier passage du numéro bio |
| `numero_bio` | `integer` | non | Clé naturelle | Annuaire |
| `siret` | `char(14)` | oui | SIRET nettoyé et valide, sinon vide | Règles du modèle § 3.3 |
| `siret_statut` | `text` | non | `VALIDE`, `ABSENT`, `TEXTE_NONE`, `FORMAT_INVALIDE`, `LUHN_INVALIDE` | Règle de contrôle |
| `denomination` | `text` | non | Nom de l'opérateur, souvent une personne | Annuaire. **Ne quitte jamais silver** |
| `code_postal` | `text` | oui | Code postal nettoyé (5 chiffres) | Annuaire |
| `code_postal_statut` | `text` | non | `CONNU_LA_POSTE`, `INCONNU_LA_POSTE`, `ABSENT` | Jointure avec `ref_code_postal_commune` |
| `code_commune` | `text` FK | oui | Commune, si elle est connue avec certitude | SIRENE, sinon La Poste si une seule commune |
| `code_departement` | `text` FK | non | Département de rattachement (`00` si inconnu) | Règle de rattachement |
| `methode_rattachement` | `text` | non | `SIRENE`, `LAPOSTE_UNIQUE`, `DEDUCTION_CP`, `ETRANGER`, `INCONNU` | Règle de rattachement |
| `hash_attributs` | `char(32)` | non | MD5 des colonnes suivies | Calculé |
| `date_debut` | `date` | non | Copie où la version apparaît | Date de copie |
| `date_fin` | `date` | oui | Copie où elle disparaît ou change | Date de copie |
| `est_courant` | `boolean` | non | Version en cours | `date_fin is null` |
| `est_chargement_initial` | `boolean` | non | Version créée par le premier chargement (2026-11-05) | Règle |
| `_execution_id` | `bigint` FK | non | Exécution qui a créé la version | `audit.execution` |

### `silver.certification` (SCD 2)

Grain : une version d'une certification (un opérateur × un organisme). Alimentation : `silver_annuaire`, quotidien. Sensibilité : interne.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `certification_version_id` | `bigint` PK identity | non | Clé technique de la version | Générée |
| `numero_bio` | `integer` | non | Clé naturelle, partie 1 | Annuaire |
| `certificateur_id` | `integer` FK | non | Clé naturelle, partie 2 | `ref_certificateur` |
| `date_engagement` | `date` | oui | Date d'engagement en bio | Annuaire. Vide pour les dispenses et les dates futures |
| `date_engagement_statut` | `text` | non | `VALIDE`, `ABSENTE`, `FUTURE` | Règle de contrôle |
| `activites_liste` | `text` | non | Activités triées et séparées par `,` (sert au calcul du hash) | Annuaire, après éclatement |
| `hash_attributs` | `char(32)` | non | MD5 des colonnes suivies | Calculé |
| `date_debut`, `date_fin`, `est_courant`, `est_chargement_initial`, `_execution_id` | | | Comme dans `operateur` | |

### `silver.certification_activite`

Grain : une version de certification × une activité. Alimentation : `silver_annuaire` (`tNormalize`). Sensibilité : interne.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `certification_version_id` | `bigint` PK, FK | non | Version de certification | `silver.certification` |
| `activite_code` | `text` PK, FK | non | Activité | `ref_activite` |

---

## Schéma `gold`

Propriétaire : data engineer. Alimentation : `gold_etoile` puis `gold_indicateurs`, quotidien, après le contrôle silver.
Rétention : recalculé à chaque exécution. Sensibilité : **interne, aucune donnée personnelle**. Accès : `etl_writer`, `qa_reader`, `bi_reader`.

### `gold.dim_date`

Grain : un jour, du 1994-01-01 au 31 décembre de l'année suivante. Alimentation : générée (aucune source).

| Colonne | Type | Null | Description |
|---|---|---|---|
| `date_id` | `integer` PK | non | `AAAAMMJJ` (`20261105`). `-1` = inconnue |
| `date` | `date` | oui | La date |
| `annee` | `smallint` | oui | `2026` |
| `trimestre` | `smallint` | oui | 1 à 4 |
| `mois` | `smallint` | oui | 1 à 12 |
| `mois_libelle` | `text` | oui | `novembre` |
| `annee_mois` | `text` | oui | `2026-11`, pour les axes de graphiques |
| `jour_semaine` | `smallint` | oui | 1 (lundi) à 7 |
| `est_fin_de_mois` | `boolean` | oui | Dernier jour du mois |

### `gold.dim_geographie`

Grain : un département, plus `99` (étranger) et `-1` (inconnu).

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `geographie_id` | `smallint` PK | non | Clé technique | Générée |
| `code_departement` | `text` | non | Code du département | `silver.ref_departement` |
| `departement_libelle` | `text` | non | Nom du département | Idem |
| `code_region` | `text` | oui | Code de la région | Idem |
| `region_libelle` | `text` | oui | Nom de la région | `silver.ref_region` |
| `est_outre_mer` | `boolean` | non | Département d'outre-mer | Idem |
| `population` | `integer` | oui | Population municipale du dernier millésime | `silver.population_departement`. Vide pour Mayotte |
| `annee_population` | `smallint` | oui | Millésime de la population | Idem |
| `nb_exploitations_ra2020` | `integer` | oui | Exploitations agricoles en 2020 | `silver.exploitation_departement` |
| `sau_ha_ra2020` | `numeric(12,2)` | oui | Surface agricole utile en 2020 | Idem |

### `gold.dim_activite`

| Colonne | Type | Null | Description | Source |
|---|---|---|---|---|
| `activite_id` | `smallint` PK | non | Clé technique (`-1` = inconnue) | Générée |
| `activite_code` | `text` | non | Code | `silver.ref_activite` |
| `activite_libelle` | `text` | non | Libellé | Idem |
| `famille` | `text` | non | Famille d'activités | Idem |

### `gold.dim_certificateur`

| Colonne | Type | Null | Description | Source |
|---|---|---|---|---|
| `certificateur_id` | `integer` PK | non | Même clé qu'en silver (`-1` = inconnu) | `silver.ref_certificateur` |
| `certificateur_libelle` | `text` | non | Nom | Idem |
| `est_dispense` | `boolean` | non | À exclure des parts de marché et du HHI | Idem |

### `gold.dim_operateur`

Grain : un opérateur (clé durable), état courant (type 1). **Aucun nom, SIRET ni numéro bio.**

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `operateur_id` | `integer` PK | non | Pseudonyme de l'opérateur (`-1` = inconnu) | `silver.operateur.operateur_id` |
| `a_siret_valide` | `boolean` | non | SIRET valide dans l'annuaire | `siret_statut = 'VALIDE'` |
| `est_trouve_sirene` | `boolean` | non | SIRET trouvé dans SIRENE | Jointure |
| `est_actif_sirene` | `boolean` | oui | Établissement actif dans SIRENE | `silver.etablissement_sirene.est_actif` |
| `code_naf` | `text` | oui | Activité principale | Idem |
| `section_naf` | `text` | oui | Grand secteur (`A` agriculture, `C` industrie, `G` commerce…) | Dérivée du code NAF |
| `tranche_effectif_libelle` | `text` | oui | Taille de l'établissement | `silver.ref_tranche_effectif` |
| `methode_rattachement` | `text` | non | Comment le département a été trouvé | `silver.operateur` |
| `nb_certifications` | `smallint` | non | Nombre de certifications en cours | Comptage |
| `est_courant` | `boolean` | non | Opérateur présent dans la dernière copie | `silver.operateur.est_courant` |

### `gold.fait_operateur_activite`

Grain : une date de copie × une certification × une activité. Rétention : 30 dernières copies quotidiennes + une par fin de mois.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `date_copie_id` | `integer` FK | non | Date de la photo | `dim_date` |
| `operateur_id` | `integer` FK | non | Opérateur | `dim_operateur` |
| `certificateur_id` | `integer` FK | non | Organisme | `dim_certificateur` |
| `activite_id` | `smallint` FK | non | Activité | `dim_activite` |
| `geographie_id` | `smallint` FK | non | Département **à la date de la copie** | `silver.operateur` *as of* |
| `date_engagement_id` | `integer` FK | non | Date d'engagement (`-1` si vide) | `dim_date`, rôle « engagement » |
| `nb_operateur_activite` | `smallint` | non | Toujours 1 : additionnable | Constante |

Clé primaire : (`date_copie_id`, `operateur_id`, `certificateur_id`, `activite_id`).
Rappel : nombre d'opérateurs = `DISTINCTCOUNT(operateur_id)`, pas `SUM(nb_operateur_activite)`.

### `gold.fait_mouvement`

Grain : un mouvement d'un opérateur à une date. Rétention : complète.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `mouvement_id` | `bigint` PK identity | non | Clé technique | Générée |
| `date_mouvement_id` | `integer` FK | non | Date de la copie où le mouvement est observé | `date_debut` ou `date_fin` en silver |
| `operateur_id` | `integer` FK | non | Opérateur | `dim_operateur` |
| `geographie_id` | `smallint` FK | non | Département au moment du mouvement | `silver.operateur` *as of* |
| `certificateur_id` | `integer` FK | non | Organisme concerné (le nouveau en cas de changement) | `silver.certification` |
| `certificateur_precedent_id` | `integer` FK | oui | Organisme quitté (changement de certificateur seulement) | Idem |
| `type_mouvement` | `text` | non | `ENTREE`, `SORTIE`, `CHANGEMENT_CERTIFICATEUR`, `CHANGEMENT_ACTIVITES`, `CHANGEMENT_DEPARTEMENT` | Règles ci-dessous |
| `nb_mouvement` | `smallint` | non | Toujours 1 | Constante |

| Type | Règle (à partir des versions silver, hors chargement initial) |
|---|---|
| `ENTREE` | Première version de certification d'un numéro bio qui n'avait aucune certification en cours la veille |
| `SORTIE` | Fermeture de la dernière certification en cours d'un numéro bio, sans nouvelle version le même jour |
| `CHANGEMENT_CERTIFICATEUR` | Le même jour, une certification se ferme et une autre s'ouvre pour le même numéro bio avec un autre organisme |
| `CHANGEMENT_ACTIVITES` | Nouvelle version de certification, même organisme, liste d'activités différente |
| `CHANGEMENT_DEPARTEMENT` | Nouvelle version d'opérateur avec un autre `code_departement` |

### `gold.ind_structure_departement` (axe 1)

Grain : un département × une date de copie.

| Colonne | Type | Description | Règle de calcul |
|---|---|---|---|
| `date_copie_id`, `geographie_id` | PK, FK | Date et département | |
| `nb_operateurs` | `integer` | Opérateurs distincts | Distinct `operateur_id` |
| `nb_producteurs` | `integer` | Opérateurs ayant l'activité Production | Distinct, `famille = 'production'` |
| `nb_preparateurs` | `integer` | Opérateurs ayant l'activité Préparation | Distinct, `famille = 'transformation'` |
| `nb_distributeurs` | `integer` | Opérateurs de la famille distribution | Distinct, `famille = 'distribution'` |
| `ratio_transformation` | `numeric(10,4)` | Préparateurs par producteur | `nb_preparateurs / nb_producteurs`, vide si aucun producteur |
| `ratio_distribution` | `numeric(10,4)` | Distributeurs par producteur | `nb_distributeurs / nb_producteurs` |
| `densite_producteurs_10k_hab` | `numeric(10,4)` | Producteurs pour 10 000 habitants | `nb_producteurs / population × 10 000` |
| `part_exploitations_bio` | `numeric(10,4)` | Part des exploitations en bio | `nb_producteurs / nb_exploitations_ra2020`. Approximation : années et définitions différentes (voir limites) |
| `quartile_producteurs` | `smallint` | Quartile du nombre de producteurs parmi les départements | 1 (bas) à 4 (haut), départements de France hors `99` et `-1` |
| `quartile_ratio_transformation` | `smallint` | Quartile du ratio de transformation | Idem |
| `est_desert_transformation` | `boolean` | Beaucoup de producteurs, peu de transformation | `quartile_producteurs = 4 and quartile_ratio_transformation = 1` |

### `gold.ind_dynamique_departement_mois` (axe 2)

Grain : un département × un mois.

| Colonne | Type | Description | Règle de calcul |
|---|---|---|---|
| `annee_mois`, `geographie_id` | PK | Mois et département | |
| `nb_engagements` | `integer` | Opérateurs engagés ce mois-là | Par `date_engagement`, historique depuis 1994 |
| `nb_entrees` | `integer` | Entrées observées | `fait_mouvement`, type `ENTREE` |
| `nb_sorties` | `integer` | Sorties observées | Type `SORTIE` |
| `solde_net` | `integer` | Entrées − sorties | `nb_entrees − nb_sorties` |
| `nb_changements_certificateur` | `integer` | Changements d'organisme | Type `CHANGEMENT_CERTIFICATEUR` |
| `croissance_engagements_an` | `numeric(10,4)` | Évolution sur un an des engagements | (mois − même mois un an avant) / même mois un an avant |
| `est_mois_observe` | `boolean` | Mois couvert par les copies quotidiennes | `false` avant novembre 2026 : entrées et sorties inconnues |

### `gold.ind_marche_region` (axe 3)

Grain : une région × un organisme × une date de copie. **Les dispenses sont exclues.**

| Colonne | Type | Description | Règle de calcul |
|---|---|---|---|
| `date_copie_id`, `code_region`, `certificateur_id` | PK | Date, région, organisme | `code_region = 'FR'` pour la France entière |
| `nb_operateurs_certifies` | `integer` | Opérateurs certifiés par l'organisme | Distinct `operateur_id` |
| `part_marche` | `numeric(10,4)` | Part de l'organisme dans la région | `nb_operateurs_certifies / total de la région` |
| `rang` | `smallint` | Rang de l'organisme dans la région | 1 = leader |
| `est_leader` | `boolean` | Organisme majoritaire | `rang = 1` |
| `hhi_region` | `numeric(10,2)` | Indice de concentration de la région (répété sur chaque ligne) | Σ (part en %)², de 0 à 10 000. > 2 500 = très concentré |

Le leader par département se calcule dans Power BI depuis `fait_operateur_activite`.

---

## Schéma `audit`

Propriétaire : data engineer. Accès : `etl_writer` (tout), `qa_reader` (lecture et insertion). Sensibilité : interne, sauf `rejet` (personnelle).

### `audit.execution`

Grain : une exécution d'un job. Rétention : 2 ans.

| Colonne | Type | Null | Description |
|---|---|---|---|
| `execution_id` | `bigint` PK identity | non | Clé technique |
| `dag_run_id` | `text` | oui | Exécution Airflow (vide pour un lancement manuel) |
| `job_nom` | `text` | non | Nom du job Talend (`silver_annuaire`) |
| `couche` | `text` | non | `bronze`, `silver`, `gold` |
| `date_copie` | `date` | oui | Version de la source traitée |
| `date_debut` | `timestamptz` | non | Début du job |
| `date_fin` | `timestamptz` | oui | Fin du job |
| `statut` | `text` | non | `EN_COURS`, `SUCCES`, `ECHEC` |
| `nb_lignes_lues` | `integer` | oui | Lignes lues en entrée |
| `nb_lignes_ecrites` | `integer` | oui | Lignes écrites en sortie |
| `nb_lignes_rejetees` | `integer` | oui | Lignes envoyées dans `audit.rejet` |
| `message` | `text` | oui | Message d'erreur en cas d'échec |

### `audit.rejet`

Grain : une ligne refusée (ou fusionnée) par un job. **Rétention : 90 jours** (peut contenir un nom de personne).

| Colonne | Type | Null | Description |
|---|---|---|---|
| `rejet_id` | `bigint` PK identity | non | Clé technique |
| `execution_id` | `bigint` FK | non | Exécution qui a rejeté la ligne |
| `table_source` | `text` | non | Table lue (`bronze.agence_bio_operateur`) |
| `hash_ligne_source` | `char(32)` | oui | `_hash_ligne` de la ligne bronze, pour la retrouver |
| `table_cible` | `text` | non | Table visée (`silver.certification`) |
| `motif_code` | `text` | non | `NUMERO_BIO_ABSENT`, `ACTIVITE_INCONNUE`, `DOUBLON_FUSIONNE`… |
| `motif_detail` | `text` | oui | Explication lisible |
| `ligne_source` | `jsonb` | non | La ligne d'origine, colonne par colonne |
| `date_rejet` | `timestamptz` | non | Horodatage |

### `audit.controle_qualite`

Grain : un contrôle exécuté par un notebook. Rétention : 2 ans.

| Colonne | Type | Null | Description |
|---|---|---|---|
| `controle_id` | `bigint` PK identity | non | Clé technique |
| `execution_id` | `bigint` FK | oui | Exécution du job contrôlé |
| `couche` | `text` | non | `bronze`, `silver`, `gold` |
| `notebook` | `text` | non | `qualite/02_silver.ipynb` |
| `nom_controle` | `text` | non | `taux_rattachement_inconnu`, `unicite_version_courante`… |
| `valeur_mesuree` | `numeric` | oui | Résultat du contrôle |
| `seuil` | `numeric` | oui | Seuil d'alerte ou d'échec |
| `statut` | `text` | non | `OK`, `ALERTE` (la chaîne continue), `ECHEC` (la chaîne s'arrête) |
| `commentaire` | `text` | oui | Détail |
| `date_controle` | `timestamptz` | non | Horodatage |

---

## Limites connues des données

| Limite | Conséquence | Traitement |
|---|---|---|
| Mayotte absente des populations 2023 | Pas de densité pour Mayotte | `population` vide, densité vide |
| Contours GeoJSON sans l'outre-mer | Pas de carte pour l'outre-mer | Outre-mer affiché en tableau, contours à ajouter plus tard |
| Les sorties ne sont visibles qu'à partir de la première copie (2026-11-05) | Pas d'entrées ni de sorties observées avant | `est_mois_observe = false` |
| RA 2020 et annuaire d'une autre année, définitions différentes (exploitation ≠ opérateur) | `part_exploitations_bio` est une approximation | Indiqué dans Power BI |
| Annuaire = siège social, SIRENE = établissement | Les deux codes postaux peuvent différer | SIRENE fait foi, écarts comptés |
| ~77 % des dénominations sont probablement des noms de personnes | Données personnelles | Restent en silver, jamais en gold |
