"""Convertit les contours des départements (GeoJSON) en TopoJSON pour Power BI.

Le visuel « Carte de formes » de Power BI n'accepte que le format TopoJSON.
Conversion minimale, sans dépendance : chaque contour (anneau) devient un
« arc » TopoJSON. Les frontières communes ne sont pas fusionnées : le fichier
est un peu plus gros qu'avec un outil spécialisé, mais le tracé est identique.

Usage :
    python powerbi/cartes/geojson_vers_topojson.py ENTREE.geojson SORTIE.topojson
"""

import json
import sys


def convertir(geojson, nom_couche="departements", decimales=4):
    """Renvoie un dictionnaire TopoJSON équivalent à une FeatureCollection."""
    arcs = []

    def ajouter_anneau(anneau):
        # 4 décimales ≈ 10 m : largement suffisant pour une carte de France.
        arcs.append([[round(x, decimales), round(y, decimales)] for x, y in anneau])
        return len(arcs) - 1

    geometries = []
    for entite in geojson["features"]:
        geometrie = entite["geometry"]
        if geometrie["type"] == "Polygon":
            arcs_geo = [[ajouter_anneau(a)] for a in geometrie["coordinates"]]
        elif geometrie["type"] == "MultiPolygon":
            arcs_geo = [
                [[ajouter_anneau(a)] for a in polygone]
                for polygone in geometrie["coordinates"]
            ]
        else:
            raise ValueError(f"Géométrie non prise en charge : {geometrie['type']}")
        geometries.append({
            "type": geometrie["type"],
            "arcs": arcs_geo,
            "properties": entite["properties"],
        })

    return {
        "type": "Topology",
        "objects": {nom_couche: {"type": "GeometryCollection", "geometries": geometries}},
        "arcs": arcs,
    }


if __name__ == "__main__":
    entree, sortie = sys.argv[1], sys.argv[2]
    with open(entree, encoding="utf-8") as f:
        topologie = convertir(json.load(f))
    with open(sortie, "w", encoding="utf-8") as f:
        json.dump(topologie, f, ensure_ascii=False, separators=(",", ":"))
    n = len(topologie["objects"]["departements"]["geometries"])
    print(f"{n} départements écrits dans {sortie}")
