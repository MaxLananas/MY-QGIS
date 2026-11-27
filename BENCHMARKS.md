# Benchmarks de performance QGIS (fork) — protocole & honnêteté

## Ce qui est mesuré

La suite `scripts/perf/qgis-perf-bench.py` mesure **de vraies opérations QGIS**
via PyQGIS, sur **des données synthétiques déterministes** générées localement
(semence `20261126` — reproductibles machine pour machine) :

| Métrique | Définition exacte |
|---|---|
| `app_init` | création de `QgsApplication` + `initQgis()` en-process, **hors écran**. **Ce n'est PAS le démarrage complet de l'UI** (celui-là se mesure en session interactive) |
| `data_generation` | génération des GeoPackages (100 000 points / 3 000 polygones par défaut) — exclue des comparaisons |
| `project_write` / `project_read` | écriture puis réouverture d'un projet `.qgs` référençant les couches |
| `render_first` | premier rendu complet (toutes couches, job parallèle réel `QgsMapRendererParallelJob`, étiquetage + rendu catégorisé) |
| `render_warm` | second rendu identique (chemin cache du renderer) |
| `pan_x10` | 10 décalages successifs de 8° (simule un pan, re-rendu complet à chaque fois) |
| `zoom_x5` | 5 zooms successifs ×2 |
| `feature_scan` | itération complète attributs+géométrie de la couche points |
| `expression_filter` | requête fournisseur avec filtre expression `"count" > 500` |
| `expression_eval` | expression préparée évaluée feature par feature (100 000) |
| `coord_transform_100k` | 100 000 reprojections 4326→3857 avec une instance de `QgsCoordinateTransform` réutilisée |
| `unique_values` | `layer.uniqueValues()` sur un champ texte |
| `processing_buffer` | algorithme natif `native:buffer` (si le plugin processing est disponible) |
| `memory_peak_rss_mb` | RSS crête du processus (Linux) |

Chaque métrique rapporte **médiane + meilleur temps** sur N répétitions.

## Règles d'honnêteté (non négociables)

1. **Ces chiffres sont réels mais sur données synthétiques.** Ils servent au
   suivi de régression (avant/après un changement, même seed, même machine) —
   ils ne remplacent pas un test sur vos projets de production.
2. **Ne jamais comparer** des machines, disques ou providers différents.
3. Toute optimisation du fork doit être validée par cette suite **avant/après**,
   avec le même jeu de données et le même nombre de répétitions.
4. `app_init` ≠ démarrage UI : ne jamais publier l'un comme l'autre.

## Exécution locale

```bash
# Dans un environnement où `import qgis.core` fonctionne (installation QGIS, docker)
scripts/perf/run-perf-bench.sh /tmp/perf-results
# variantes :
PERF_LABEL=after-fix PERF_REPEATS=5 scripts/perf/run-perf-bench.sh /tmp/after
```

## Exécution en CI

Workflow manuel **📊 Performance benchmark** (`.github/workflows/perf-bench.yml`)
: build de QGIS (config rapide **avec Python**), génération des données,
exécution sous `xvfb-run` dans l'image Docker build-deps, tableau complet dans
l'onglet *Summary* du run. Déclenchement uniquement via le bouton
« Run workflow » — jamais automatiquement (coût nul par défaut).

## Ce que la suite ne couvre volontairement pas (et pourquoi)

- **Démarrage UI complet** : nécessite une session graphique — mesurez-le
  interactivement (`qgis --profile-log` / chronométrage manuel, même matériel).
- **Providers distants** (PostGIS/WFS/COG http) : dépendent du réseau —
  faites-les sur votre infrastructure si pertinent ; la suite reste un
  socle déterministe.
- **PAL (étiquetage avancé)** : les temps d'étiquetage sont inclus dans les
  rendus, mais un benchmark PAL isolé exige un jeu de géométries adverses —
  à ajouter plus tard avec des données réelles.
