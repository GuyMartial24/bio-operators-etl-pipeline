# Image Airflow du projet : l'image officielle, plus Java pour exécuter les jobs Talend exportés.
FROM apache/airflow:3.3.2-python3.12

# L'installation de paquets système demande les droits administrateur
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends openjdk-17-jre-headless \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Dossier du fichier des mots de passe de l'interface (volume airflow_auth),
# créé à l'avance pour que l'utilisateur airflow puisse y écrire
RUN mkdir -p /opt/airflow/auth && chown airflow:root /opt/airflow/auth

# Retour à l'utilisateur non privilégié prévu par l'image officielle
USER airflow

# Exécution du notebook de contrôle qualité (papermill lance le notebook, ipykernel exécute les cellules)
RUN pip install --no-cache-dir papermill==2.6.0 ipykernel==6.30.1

