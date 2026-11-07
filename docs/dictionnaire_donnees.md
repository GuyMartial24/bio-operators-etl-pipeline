# Dictionnaire de données — Observatoire territorial de la filière bio

Chaque table et chaque colonne : ce qu'elle contient, d'où elle vient, comment elle est calculée.
Les choix de modélisation sont justifiés dans le [modèle de données](modele_donnees.md).

Chaque table a une fiche : **grain** (ce que représente une ligne), **alimentation** (job et fréquence), **rétention**,
**sensibilité** (`Publique`, `Interne` = dérivée sans donnée personnelle, `Personnelle` = RGPD) et **accès** (rôles PostgreSQL).
Propriétaire de toutes les tables : le data engineer du projet. Colonne **Null** : `non` si la valeur est obligatoire.

---

## Schéma `bronze`

Toutes les colonnes de source sont en `text`, sans transformation. Accès : `etl_writer`, `qa_reader`.

### Colonnes techniques, communes à toutes les tables bronze

| Colonne | Type | Null | Description |
|---|---|---|---|
| `_execution_id` | `bigint` | non | Exécution qui a chargé la ligne (`audit.execution`) |
| `_date_copie` | `date` | non | Date de la version de la source. Source annuelle : 1er janvier du millésime (`2026-01-01` pour le COG 2026) |
| `_fichier_source` | `text` | non | Chemin du fichier, relatif à `data/raw` |
| `_numero_ligne` | `integer` | non | Numéro de la ligne dans le fichier, hors en-tête |
| `_hash_ligne` | `char(32)` | non | MD5 des valeurs de la ligne séparées par `;` (identique à `md5(concat_ws(';', …))` de PostgreSQL) |
| `_date_chargement` | `timestamptz` | non | Horodatage de l'écriture (`DEFAULT now()`) |

### Tables bronze

| Table | Grain | Alimentation | Rétention | Sensibilité |
|---|---|---|---|---|
| `agence_bio_operateur` | Une ligne de l'annuaire, pour une copie | `bronze_agence_bio`, quotidien | 30 dernières copies | **Personnelle** (`denomination`) |
| `insee_cog_departement` | Un département | `bronze_insee`, annuel | Une version par millésime | Publique |
| `insee_cog_region` | Une région | `bronze_insee`, annuel | Une version par millésime | Publique |
| `insee_population_departement` | Un département | `bronze_insee`, annuel | Une version par millésime | Publique |

Colonnes de `agence_bio_operateur` :

| Colonne | Colonne d'origine | Exemple | Remarques de l'exploration |
|---|---|---|---|
| `siret` | `SIRET` | `38459550000024` | 701 vides (`''`), 75 `None`, 1 caractère invisible, 11 clés de Luhn invalides |
| `numero_bio` | `NUMERO BIO` | `1` | 69 valeurs présentes deux fois |
| `denomination` | `DENOMINATION` | `LES PAPILLONS DU LARRY` | ~77 % contiennent probablement un nom de personne |
| `code_postal_siege_social` | `CODE POSTAL SIEGE SOCIAL` | `51120` | Espaces finaux, un zéro de tête perdu |
| `dateengagement` | `DATEENGAGEMENT` | `2020-07-08` | 1 322 `None` (dispenses), 6 dates futures |
| `activites` | `ACTIVITES` | `Production,Préparation` | 1 à 6 valeurs parmi 8 |
| `organisme_certificateur` | `ORGANISME CERTIFICATEUR` | `Ecocert France` | 10 valeurs, dont « Dispense de certification » |

Les colonnes des tables INSEE reprennent celles des fichiers (voir le [modèle de données, § 3.2](modele_donnees.md#32-bronze--la-copie-fidèle-des-sources)).

---

## Schéma `silver`

Accès : `etl_writer`, `qa_reader`. **Aucun accès pour `bi_reader`.**

### `silver.ref_region`

Grain : une région. Alimentation : `silver_referentiels`, annuel. Sensibilité : publique.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `code_region` | `text` PK | non | Code INSEE (`84`) | COG `REG` |
| `region_libelle` | `text` | non | Nom (`Auvergne-Rhône-Alpes`) | COG `LIBELLE` |
| `millesime_cog` | `smallint` | non | Année du COG | Version de la source |

### `silver.ref_departement`

Grain : un département, plus deux membres spéciaux. Alimentation : `silver_referentiels`, annuel. Sensibilité : publique.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `code_departement` | `text` PK | non | `01`…`95`, `2A`, `2B`, `971`…`976`. Membres spéciaux : `99` étranger, `00` inconnu | COG `DEP` |
| `departement_libelle` | `text` | non | Nom | COG `LIBELLE` |
| `code_region` | `text` FK | oui | Région (vide pour `99` et `00`) | COG `REG` |
| `est_outre_mer` | `boolean` | non | Code sur 3 caractères | Règle |
| `millesime_cog` | `smallint` | non | Année du COG | Version de la source |

### `silver.population_departement`

Grain : un département × une année. Sensibilité : publique.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `code_departement` | `text` PK, FK | non | Département | INSEE `DEP` |
| `annee` | `smallint` PK | non | Année de référence (`2023`) | Version de la source |
| `population_municipale` | `integer` | non | Population municipale | INSEE `PMUN`. Mayotte absente du millésime 2023 |

### `silver.ref_activite`

Grain : une activité. Alimentation : `silver_referentiels` (8 valeurs fixes). Sensibilité : publique.

| Colonne | Type | Null | Description |
|---|---|---|---|
| `activite_code` | `text` PK | non | Code en majuscules sans accent (`PREPARATION`) |
| `activite_libelle` | `text` | non | Libellé de l'annuaire (`Préparation`) |
| `famille` | `text` | non | `production`, `transformation`, `distribution`, `logistique`, `echanges` |

### `silver.ref_certificateur`

Grain : un organisme. Alimentation : `silver_annuaire` (ajout des organismes nouveaux). Sensibilité : publique.

| Colonne | Type | Null | Description |
|---|---|---|---|
| `certificateur_id` | `integer` PK identity | non | Clé technique |
| `certificateur_libelle` | `text` unique | non | Nom de l'annuaire |
| `est_dispense` | `boolean` | non | `true` pour « Dispense de certification » |
| `date_premiere_observation` | `date` | non | Première copie où l'organisme apparaît |

### `silver.operateur` (SCD 1)

Grain : un opérateur, état courant. Alimentation : `silver_annuaire`, quotidien. Rétention : illimitée.
**Sensibilité : personnelle** (`denomination`, `siret` d'entrepreneurs individuels).

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `operateur_id` | `integer` PK identity | non | Clé technique stable, pseudonyme utilisé en gold | Générée au premier passage |
| `numero_bio` | `integer` unique | non | Clé naturelle | Annuaire |
| `siret` | `char(14)` | oui | SIRET nettoyé et valide, sinon vide | Règles du modèle § 3.3 |
| `siret_statut` | `text` | non | `VALIDE`, `ABSENT`, `TEXTE_NONE`, `FORMAT_INVALIDE`, `LUHN_INVALIDE` | Règle |
| `denomination` | `text` | non | Nom de l'opérateur. **Ne quitte jamais silver** | Annuaire |
| `code_postal` | `text` | oui | Code postal nettoyé (5 chiffres) | Annuaire |
| `code_postal_statut` | `text` | non | `VALIDE`, `ABSENT`, `FORMAT_INVALIDE` | Règle |
| `code_departement` | `text` FK | non | Département de rattachement (`00` si inconnu) | Règle du modèle § 3.3 |
| `methode_rattachement` | `text` | non | `CODE_POSTAL`, `ETRANGER`, `INCONNU` | Règle |
| `est_present` | `boolean` | non | Présent dans la dernière copie | Comparaison avec la copie du jour |
| `date_premiere_observation` | `date` | non | Première copie où l'opérateur apparaît | Date de copie |
| `date_derniere_observation` | `date` | non | Dernière copie où il apparaît | Date de copie |

### `silver.certification` (SCD 2)

Grain : une version d'une certification (opérateur × organisme). Alimentation : `silver_annuaire`, quotidien. Sensibilité : interne.

| Colonne | Type | Null | Description | Source / règle |
|---|---|---|---|---|
| `certification_version_id` | `bigint` PK identity | non | Clé technique de la version | Générée |
| `numero_bio` | `integer` FK | non | Clé naturelle, partie 1 | Annuaire |
| `certificateur_id` | `integer` FK | non | Clé naturelle, partie 2 | `ref_certificateur` |
| `date_engagement` | `date` | oui | Date d'engagement en bio | Vide pour les dispenses et les dates futures |
| `date_engagement_statut` | `text` | non | `VALIDE`, `ABSENTE`, `FUTURE` | Règle |
| `activites_liste` | `text` | non | Codes d'activités triés, séparés par `,` | Après éclatement |
| `hash_attributs` | `char(32)` | non | MD5 de `date_engagement` et `activites_liste` | Calculé |
| `date_debut` | `date` | non | Copie où la version apparaît | Date de copie |
| `date_fin` | `date` | oui | Copie où elle change ou disparaît | Date de copie |
| `est_courant` | `boolean` | non | Version en cours | `date_fin is null` |
| `est_chargement_initial` | `boolean` | non | Créée par le premier chargement (2026-11-05) | Règle |
| `_execution_id` | `bigint` FK | non | Exécution qui a créé la version | `audit.execution` |

### `silver.certification_activite`

Grain : une version de certification × une activité. Alimentation : `silver_annuaire`. Sensibilité : interne.

| Colonne | Type | Null | Description |
|---|---|---|---|
| `certification_version_id` | `bigint` PK, FK | non | Version de certification |
| `activite_code` | `text` PK, FK | non | Activité |

---

## Schéma `gold`

Alimentation : `gold_etoile`, quotidien, recalculé entièrement. Sensibilité : **interne, aucune donnée personnelle**.
Accès : `etl_writer`, `qa_reader`, `bi_reader`.

### `gold.dim_date`

Grain : un jour, du 1994-01-01 au 31 décembre de l'année suivante. Générée sans source.

| Colonne | Type | Null | Description |
|---|---|---|---|
| `date_id` | `integer` PK | non | `AAAAMMJJ`. `-1` = inconnue |
| `date` | `date` | oui | La date |
| `annee` | `smallint` | oui | `2026` |
| `trimestre` | `smallint` | oui | 1 à 4 |
| `mois` | `smallint` | oui | 1 à 12 |
| `mois_libelle` | `text` | oui | `novembre` |

### `gold.dim_departement`

Grain : un département, plus `99` (étranger), `00` et `-1` (inconnu).

| Colonne | Type | Null | Description | Source |
|---|---|---|---|---|
| `departement_id` | `smallint` PK | non | Clé technique | Générée |
| `code_departement` | `text` | non | Code, joint aux contours GeoJSON dans Power BI | `silver.ref_departement` |
| `departement_libelle` | `text` | non | Nom | Idem |
| `code_region`, `region_libelle` | `text` | oui | Région | `silver.ref_region` |
| `est_outre_mer` | `boolean` | non | Outre-mer | Idem |
| `population` | `integer` | oui | Population municipale du dernier millésime. Vide pour Mayotte | `silver.population_departement` |
| `annee_population` | `smallint` | oui | Millésime | Idem |

### `gold.dim_activite`

| Colonne | Type | Null | Description |
|---|---|---|---|
| `activite_id` | `smallint` PK | non | Clé technique (`-1` = inconnue) |
| `activite_libelle` | `text` | non | Libellé |
| `famille` | `text` | non | Famille d'activités |

### `gold.dim_certificateur`

| Colonne | Type | Null | Description |
|---|---|---|---|
| `certificateur_id` | `integer` PK | non | Même clé qu'en silver (`-1` = inconnu) |
| `certificateur_libelle` | `text` | non | Nom |
| `est_dispense` | `boolean` | non | À exclure des parts de marché et du HHI |

### `gold.fait_certification_activite`

Grain : une certification en cours × une activité. Clé primaire : (`operateur_id`, `certificateur_id`, `activite_id`).

| Colonne | Type | Null | Description | Source |
|---|---|---|---|---|
| `operateur_id` | `integer` | non | Pseudonyme de l'opérateur (dimension dégénérée) | `silver.operateur` |
| `certificateur_id` | `integer` FK | non | Organisme | `silver.certification` |
| `activite_id` | `smallint` FK | non | Activité | `silver.certification_activite` |
| `departement_id` | `smallint` FK | non | Département de l'opérateur | `silver.operateur` |
| `date_engagement_id` | `integer` FK | non | Date d'engagement (`-1` si vide) | `silver.certification` |
| `nb_operateur_activite` | `smallint` | non | Toujours 1 | Constante |

Nombre d'opérateurs = `DISTINCTCOUNT(operateur_id)`, pas `SUM(nb_operateur_activite)`.

### Mesures Power BI (calculées en DAX sur l'étoile)

| Mesure | Règle |
|---|---|
| Nb opérateurs | `DISTINCTCOUNT(operateur_id)` |
| Nb producteurs / préparateurs / distributeurs | Nb opérateurs filtré sur la famille `production` / `transformation` / `distribution` |
| Ratio de transformation | Préparateurs / producteurs |
| Ratio de distribution | Distributeurs / producteurs |
| Densité | Producteurs / population × 10 000 |
| Désert de transformation | Département dans le quartile haut des producteurs et le quartile bas du ratio de transformation |
| Part de marché | Opérateurs certifiés par l'organisme / total de la région, hors dispenses |
| HHI | Σ (part de marché en %)², de 0 à 10 000 ; > 2 500 = très concentré |
| Engagements par année | Nb opérateurs par `dim_date[annee]` de la date d'engagement |

---

## Schéma `audit`

Accès : `etl_writer` (tout), `qa_reader` (lecture, insertion dans `controle_qualite`). Sensibilité : interne, sauf `rejet` (personnelle).

### `audit.execution`

Grain : une exécution d'un job. Rétention : 2 ans.

| Colonne | Type | Null | Description |
|---|---|---|---|
| `execution_id` | `bigint` PK identity | non | Clé technique |
| `dag_run_id` | `text` | oui | Exécution Airflow (vide pour un lancement manuel) |
| `job_nom` | `text` | non | Nom du job Talend |
| `couche` | `text` | non | `bronze`, `silver`, `gold` |
| `date_copie` | `date` | oui | Version de la source traitée. Vide si le job lit plusieurs versions (`bronze_insee` : COG 2026 et populations 2023) |
| `date_debut` | `timestamptz` | non | Début du job (`DEFAULT now()`) |
| `date_fin` | `timestamptz` | oui | Fin du job ; obligatoire si le statut n'est plus `EN_COURS` |
| `statut` | `text` | non | `EN_COURS`, `SUCCES`, `ECHEC` |
| `nb_lignes_lues`, `nb_lignes_ecrites`, `nb_lignes_rejetees` | `integer` | oui | Volumes |
| `message` | `text` | oui | Message d'erreur ou explication |

### `audit.rejet`

Grain : une ligne refusée ou fusionnée. **Rétention : 90 jours** (peut contenir un nom).

| Colonne | Type | Null | Description |
|---|---|---|---|
| `rejet_id` | `bigint` PK identity | non | Clé technique |
| `execution_id` | `bigint` FK | non | Exécution qui a rejeté la ligne |
| `table_source`, `table_cible` | `text` | non | Table lue, table visée |
| `hash_ligne_source` | `char(32)` | oui | `_hash_ligne` de la ligne bronze |
| `motif_code` | `text` | non | `NUMERO_BIO_ABSENT`, `ACTIVITE_INCONNUE`, `DOUBLON_FUSIONNE`… |
| `motif_detail` | `text` | oui | Explication |
| `ligne_source` | `jsonb` | non | La ligne d'origine |
| `date_rejet` | `timestamptz` | non | Horodatage |

### `audit.controle_qualite`

Grain : un contrôle exécuté par le notebook. Rétention : 2 ans.

| Colonne | Type | Null | Description |
|---|---|---|---|
| `controle_id` | `bigint` PK identity | non | Clé technique |
| `execution_id` | `bigint` FK | oui | Exécution du job contrôlé |
| `couche` | `text` | non | `bronze`, `silver`, `gold` |
| `notebook` | `text` | non | `qualite/controle_qualite.ipynb` |
| `nom_controle` | `text` | non | `nb_lignes_bronze`, `unicite_version_courante`… |
| `valeur_mesuree`, `seuil` | `numeric` | oui | Résultat, seuil |
| `statut` | `text` | non | `OK`, `ALERTE` (la chaîne continue), `ECHEC` (la chaîne s'arrête) |
| `commentaire` | `text` | oui | Détail |
| `date_controle` | `timestamptz` | non | Horodatage |

---

## Limites connues

| Limite | Conséquence | Traitement |
|---|---|---|
| Département déduit du code postal | Quelques opérateurs rattachés au département voisin (< 1 %) | Méthode tracée dans `methode_rattachement` |
| Mayotte absente des populations 2023 | Pas de densité pour Mayotte | Population vide |
| Contours GeoJSON sans l'outre-mer | Pas de carte pour l'outre-mer | Outre-mer affiché en tableau |
| Sorties et changements de certificateur visibles seulement à partir du 2026-11-05 | Pas d'historique antérieur | Historisés en silver, ajoutés au tableau de bord plus tard |
| ~77 % des dénominations sont des noms de personnes | Données personnelles | Restent en silver |
