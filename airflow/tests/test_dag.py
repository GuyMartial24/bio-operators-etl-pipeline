"""Vérifie le DAG pipeline_bio sans l'exécuter.

Lancé par la CI dans l'image officielle d'Airflow (même version que le
projet) : le DAG doit se charger sans erreur, avec ses tâches et ses
dépendances.
Usage : python airflow/tests/test_dag.py DOSSIER_DES_DAGS
"""

import sys

from airflow.dag_processing.dagbag import DagBag

# Dépendances attendues : tâche -> tâches qui doivent réussir avant elle.
DEPENDANCES = {
    "telecharger_annuaire": set(),
    "bronze_agence_bio": {"telecharger_annuaire"},
    "bronze_insee": set(),
    "silver_referentiels": {"bronze_insee"},
    "silver_annuaire": {"bronze_agence_bio", "silver_referentiels"},
    "gold_etoile": {"silver_annuaire"},
    "controle_qualite": {"gold_etoile"},
}


def main(dossier):
    # Exemples d'Airflow exclus par AIRFLOW__CORE__LOAD_EXAMPLES=False.
    sac = DagBag(dag_folder=dossier)

    if sac.import_errors:
        for fichier, erreur in sac.import_errors.items():
            print(f"Erreur d'import dans {fichier} :\n{erreur}")
        sys.exit(1)

    # sac.dags : les DAG lus dans les fichiers, sans base de métadonnées.
    dag = sac.dags.get("pipeline_bio")
    if dag is None:
        sys.exit("Le DAG pipeline_bio est introuvable")

    trouvees = {t.task_id: set(t.upstream_task_ids) for t in dag.tasks}
    if trouvees != DEPENDANCES:
        print("Dépendances attendues :", DEPENDANCES)
        print("Dépendances trouvées  :", trouvees)
        sys.exit("Les tâches ou leurs dépendances ont changé")

    if dag.max_active_runs != 1:
        sys.exit("max_active_runs doit valoir 1 (copies dans l'ordre)")
    if str(dag.timezone) not in ("Europe/Paris", "Timezone('Europe/Paris')"):
        sys.exit(f"Fuseau inattendu : {dag.timezone}")

    print(f"DAG pipeline_bio : {len(dag.tasks)} tâches, dépendances conformes")


if __name__ == "__main__":
    main(sys.argv[1])
