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

from datetime import timedelta

import pendulum
from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import DAG

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
PARAMETRE_DATE_COPIE = (
    " --context_param date_copie="
    "{{ logical_date.in_timezone('" + FUSEAU + "').strftime('%Y-%m-%d') }}"
)


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
    bronze_agence_bio = job_talend("bronze_agence_bio", avec_date_copie=True)
    bronze_insee = job_talend("bronze_insee")

    # Couche silver : référentiels, puis annuaire nettoyé et historisé.
    silver_referentiels = job_talend("silver_referentiels")
    silver_annuaire = job_talend("silver_annuaire", avec_date_copie=True)

    # Couche gold : l'étoile, recalculée entièrement.
    gold_etoile = job_talend("gold_etoile")

    # Dépendances : « a >> b » signifie « a doit réussir avant b ».
    # silver_annuaire attend l'annuaire en bronze et ref_departement en silver.
    bronze_insee >> silver_referentiels
    [bronze_agence_bio, silver_referentiels] >> silver_annuaire >> gold_etoile
