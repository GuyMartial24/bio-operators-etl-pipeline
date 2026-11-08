"""Vérifie le notebook de contrôle qualité sans l'exécuter (lancé par la CI).

- le fichier respecte le format des notebooks Jupyter ;
- une cellule porte l'étiquette « parameters », indispensable à papermill
  pour injecter date_copie depuis Airflow ;
- chaque cellule de code est du Python syntaxiquement valide ;
- aucune cellule n'a enregistré d'erreur à sa dernière exécution.

Usage : python notebooks/qualite/verifier_notebook.py NOTEBOOK.ipynb
"""

import ast
import sys

import nbformat


def main(chemin):
    nb = nbformat.read(chemin, as_version=4)
    nbformat.validate(nb)

    codes = [c for c in nb.cells if c.cell_type == "code"]
    parametres = [
        c for c in codes if "parameters" in c.metadata.get("tags", [])
    ]
    if len(parametres) != 1:
        sys.exit("Il faut exactement une cellule étiquetée « parameters »")
    if "date_copie" not in parametres[0].source:
        sys.exit("La cellule « parameters » doit définir date_copie")

    for numero, cellule in enumerate(codes, start=1):
        try:
            ast.parse(cellule.source)
        except SyntaxError as erreur:
            sys.exit(f"Cellule de code n° {numero} : {erreur}")
        for sortie in cellule.get("outputs", []):
            if sortie.get("output_type") == "error":
                sys.exit(f"Cellule de code n° {numero} : erreur enregistrée")

    print(f"{chemin} : {len(codes)} cellules de code valides")


if __name__ == "__main__":
    main(sys.argv[1])
