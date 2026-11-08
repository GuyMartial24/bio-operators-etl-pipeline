"""Pipeline quotidien de l'observatoire territorial de la filière bio.

Enchaîne les cinq jobs Talend du projet, de la copie brute au modèle en
étoile lu par Power BI :

    bronze_insee ──▶ silver_referentiels ──┐
                                           ├──▶ silver_annuaire ──▶ gold_etoile
    bronze_agence_bio ─────────────────────┘

Chaque tâche exécute un job exporté par Talend (« Build Job »). Les exports
sont dans talend/build sur le PC, montés en lecture seule dans le conteneur
sous /opt/talend/jobs (voir docker-compose.yml). Les jobs lisent leurs
réglages (hôte, mot de passe, dossier des données) dans le fichier indiqué
par la variable d'environnement TALEND_CONTEXTE.
"""

import logging
from datetime import timedelta
from pathlib import Path

import pendulum
import requests
from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import DAG, task


# Dossier des jobs exportés, côté conteneur (partie droite du volume
# « ./talend/build:/opt/talend/jobs:ro » dans docker-compose.yml).
DOSSIER_JOBS = "/opt/talend/jobs"

# Fuseau du projet : planification et dates de copie à l'heure de Paris.
FUSEAU = "Europe/Paris"

# Argument transmis aux jobs qui traitent une copie datée de l'annuaire.
# Le modèle Jinja est remplacé, au moment de l'exécution, par la date
# logique au format AAAA-MM-JJ. La relance d'un jour passé retraite donc
# exactement la copie de ce jour-là.
# On convertit la date logique à l'heure de Paris avant de la formater :
# {{ ds }} la formaterait en UTC, et minuit à Paris (23 h UTC la veille)
# donnerait la copie de la veille.
DATE_COPIE = (
    "{{ logical_date.in_timezone('" + FUSEAU + "').strftime('%Y-%m-%d') }}"
)
PARAMETRE_DATE_COPIE = " --context_param date_copie=" + DATE_COPIE

# Notebook de contrôle qualité (volume ./notebooks, en lecture seule) et
# dossier de ses rapports : le notebook exécuté, avec ses résultats, est
# rangé avec les journaux d'Airflow (volume airflow_logs).
NOTEBOOK_QUALITE = "/opt/airflow/notebooks/qualite/controle_qualite.ipynb"
DOSSIER_RAPPORTS = "/opt/airflow/logs/qualite"


# Adresse stable de l'annuaire sur data.gouv.fr : elle redirige toujours
# vers la dernière version, publiée chaque nuit par l'Agence Bio.
URL_ANNUAIRE = (
    "https://www.data.gouv.fr/api/1/datasets/r/"
    "657789db-d349-4554-aef6-eabde4bd1c57"
)

# Dossier des copies, côté conteneur : une copie par date, comme
# l'attend le job bronze_agence_bio.
DOSSIER_ANNUAIRE = Path("/opt/airflow/data/raw/agence_bio")

# En-tête attendu : s'il change, la source a changé de structure et le
# job bronze échouerait plus loin, avec un message moins clair.
EN_TETE_ANNUAIRE = (
    "SIRET;NUMERO BIO;DENOMINATION;CODE POSTAL SIEGE SOCIAL;"
    "DATEENGAGEMENT;ACTIVITES;ORGANISME CERTIFICATEUR"
)

log = logging.getLogger(__name__)


@task
def telecharger_annuaire(logical_date=None):
    """Télécharge la copie du jour de l'annuaire, si elle n'existe pas.

    Args:
        logical_date: date logique de l'exécution, fournie par Airflow.

    Returns:
        Le chemin du fichier de la copie, côté conteneur.

    Raises:
        ValueError: copie d'un jour passé introuvable, ou en-tête inattendu.
    """
    date_copie = logical_date.in_timezone(FUSEAU).strftime("%Y-%m-%d")
    fichier = DOSSIER_ANNUAIRE / date_copie / "operateursbio.csv"

    # Idempotence : une copie déjà téléchargée n'est jamais remplacée.
    # Relancer un jour passé retraite donc la copie de ce jour-là.
    if fichier.exists():
        log.info("Copie déjà présente : %s", fichier)
        return str(fichier)

    # La source ne fournit que la dernière version : on ne télécharge
    # que pour la date du jour.
    if date_copie != pendulum.now(FUSEAU).strftime("%Y-%m-%d"):
        raise ValueError(
            f"Copie du {date_copie} absente : la source ne fournit que "
            "la version du jour."
        )

    reponse = requests.get(URL_ANNUAIRE, timeout=120)
    reponse.raise_for_status()
    contenu = reponse.content

    premiere_ligne = contenu.split(b"\n", 1)[0].decode("utf-8").strip()
    if premiere_ligne != EN_TETE_ANNUAIRE:
        raise ValueError(f"En-tête inattendu : {premiere_ligne!r}")

    # Écriture dans un fichier temporaire, puis renommage : le job bronze
    # ne peut jamais lire un fichier à moitié écrit.
    fichier.parent.mkdir(parents=True, exist_ok=True)
    temporaire = fichier.with_suffix(".tmp")
    temporaire.write_bytes(contenu)
    temporaire.replace(fichier)
    log.info("%d octets écrits dans %s", len(contenu), fichier)
    return str(fichier)


def job_talend(nom, avec_date_copie=False):
    """Crée la tâche qui lance un job Talend exporté.

    Args:
        nom: nom du job Talend, qui est aussi celui de son dossier
            d'export et le préfixe de son script de lancement.
        avec_date_copie: True pour les jobs qui traitent la copie du jour
            de l'annuaire (ils reçoivent la date logique comme date_copie).

    Returns:
        Un BashOperator. La tâche échoue si le job se termine avec un code
        de sortie différent de 0.
    """
    # « sh » lance le script sans dépendre de son droit d'exécution.
    commande = f"sh {DOSSIER_JOBS}/{nom}/{nom}_run.sh"
    if avec_date_copie:
        commande += PARAMETRE_DATE_COPIE
    # Espace final volontaire : une commande qui se termine par « .sh »
    # serait prise par Airflow pour le nom d'un fichier modèle Jinja
    # (erreur TemplateNotFound).
    return BashOperator(task_id=nom, bash_command=commande + " ")


with DAG(
    dag_id="pipeline_bio",
    description="Annuaire Agence Bio et INSEE : bronze, silver, gold",
    # Expression cron : minute 0, heure 6, tous les jours.
    schedule="0 6 * * *",
    # Fuseau de Paris : 6 h toute l'année, même après un changement
    # d'heure.
    start_date=pendulum.datetime(2026, 11, 5, tz=FUSEAU),
    # Pas de rattrapage automatique des jours passés depuis start_date.
    catchup=False,
    # Une seule exécution à la fois : la SCD 2 de silver exige de traiter
    # les copies dans l'ordre chronologique.
    max_active_runs=1,
    # Réglages communs à toutes les tâches : deux relances à 5 minutes
    # d'intervalle. Sans danger, car les jobs sont idempotents.
    default_args={
        "retries": 2,
        "retry_delay": timedelta(minutes=5),
    },
    tags=["bio", "talend"],
):
    # Couche bronze : copie fidèle des sources. Les deux jobs sont
    # indépendants et s'exécutent en parallèle.
        # Acquisition : la copie du jour de l'annuaire, avant la couche bronze.
    telecharger = telecharger_annuaire()
    bronze_agence_bio = job_talend("bronze_agence_bio", avec_date_copie=True)
    bronze_insee = job_talend("bronze_insee")

    # Couche silver : référentiels, puis annuaire nettoyé et historisé.
    silver_referentiels = job_talend("silver_referentiels")
    silver_annuaire = job_talend("silver_annuaire", avec_date_copie=True)

    # Couche gold : l'étoile, recalculée entièrement.
    gold_etoile = job_talend("gold_etoile")
    
    # Contrôle qualité : le notebook vérifie les données réelles et
    # enregistre ses résultats dans audit.controle_qualite.
    controle_qualite = BashOperator(
        task_id="controle_qualite",
        bash_command=(
            f"mkdir -p {DOSSIER_RAPPORTS} && papermill {NOTEBOOK_QUALITE} "
            f"{DOSSIER_RAPPORTS}/controle_qualite_{DATE_COPIE}.ipynb "
            f"-p date_copie {DATE_COPIE}"
        ),
        # Relancer ne corrigerait pas des données fausses.
        retries=0,
    )


    # Dépendances : « a >> b » signifie « a doit réussir avant b ».
    # silver_annuaire attend l'annuaire en bronze et ref_departement en silver.
    bronze_insee >> silver_referentiels
    [bronze_agence_bio, silver_referentiels] >> silver_annuaire >> gold_etoile
    telecharger >> bronze_agence_bio
    gold_etoile >> controle_qualite


