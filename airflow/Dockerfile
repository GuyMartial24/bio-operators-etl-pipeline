# Image Airflow du projet : l'image officielle, plus Java pour exécuter les jobs Talend exportés.
FROM apache/airflow:3.3.2-python3.12

# L'installation de paquets système demande les droits administrateur
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends openjdk-17-jre-headless \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Retour à l'utilisateur non privilégié prévu par l'image officielle
USER airflow
