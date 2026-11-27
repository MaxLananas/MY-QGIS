# Audit architectural QGIS (fork) — constats vérifiés & feuille de route

> Date : novembre 2026 · branche : `arena/11fc69e5-my-qgis`
> Méthode : lecture approfondie du code des chemins chauds + analyse de
> performances du système de build (voir `BENCHMARKS.md` pour la mesure des
> opérations QGIS elles-mêmes). Chaque constat cite ses sources fichier:ligne.

## 1. Ce qui a été vérifié ligne par ligne (et s'avère déjà bien conçu)

Il faut le dire franchement : le cœur de QGIS a été optimisé pendant des
années par l'amont, et plusieurs pistes « évidentes » se sont révélées
**déjà traitées** quand on ouvre le code :

| Composant | Preuve de maturité (lecture) | Verdict |
|---|---|---|
| Cache de rendu | `src/core/maprenderer/qgsmaprenderercache.cpp` : clés par couche avec validation extent+MapToPixel (`setCacheImageWithParameters`, l.135–174), seuils d'échelle pour l'invalidation partielle (`hasAnyCacheImage`, l.191+), déconnexion des couches supprimées (`dropUnusedConnections`, l.57) | ✔ mature — ne pas toucher |
| Rendu parallèle | `qgsmaprendererparalleljob.cpp` : `QtConcurrent::map` sur le pool global (l.74–80), second passe pour les couches dépendantes (l.119–123), annulation propre (l.101–167) | ✔ mature |
| Nombre de threads | `qgsapplication.cpp:2519–2546` : borne 1..nCœurs, plancher à 2 (anti-deadlock Qt), configurable | ✔ sain |
| Moteur d'expressions | `qgsexpression.cpp:373–426` : parse une fois, `prepare()` par contexte, `evaluate()` prépare paresseusement (`mIsPrepared`), calculatrice géo créée seulement si nécessaire (`geomCalculator()`) | ✔ mature — la mémoïsation par feature serait **incorrecte** (résultats dépendants du contexte) |
| Provider OGR | `qgsogrfeatureiterator.cpp:137,299` : pushdown des champs pertinents (`setRelevantFields`), non-chargement de la géométrie quand inutile (`mFetchGeometry`), filtres délégués à GDAL | ✔ mature |
| Table attributaire | `qgsattributetablemodel.cpp:466–513` : le chargement en masse réutilise la feature de l'itérateur (pas de N+1 — hypothèse testée puis infirmée), `reload()` est protégé par `mResettingModel` (l.120–122) pendant les resets | ✔ mature |

**Conséquence d'ingénierie** : patcher ces fichiers « à l'aveugle » (sans
environnement de build + tests) aurait été du théâtre, pas de
l'ingénierie. Le fork apporte donc prioritairement de la **mesure** et des
**améliorations vérifiables**, avec une feuille de route pour le reste.

## 2. Améliorations livrées dans ce fork (implémentées, pas seulement suggérées)

### Performance
1. **Cache d'images par défaut à 256 Mo** (`resources/qgis_global_settings.ini`,
   clé `cache/max-image-size` — vérifiée jusqu'à
   `QgsImageCache` / `sTreeNetworkCache`, `qgsimagecache.cpp:100`). L'amont
   calcule ~100 Mo quand la valeur vaut 0 ; les projets à symbologie SVG
   riche re-rendent les mêmes images en boucle. Valeur doublée-commentée,
   réversible par l'utilisateur (`0` = auto).
2. **Architecture de build rapide à 3 niveaux + benchmarks C++** (voir
   `BENCHMARKS.md` et `FORK-NOTES.md`) : mesure du build elle-même
   (unity/PCH/ccache/mold), avec chiffres réels.

### Diagnostic & mesure (le manque historique du SIG desktop)
3. **`scripts/perf/qgis-perf-bench.py`** : suite PyQGIS complète couvrant
   rendu (job parallèle réel), pan/zoom, projet, scans de features, moteur
   d'expressions, transformations de coordonnées, processing, RSS crête —
   sur données synthétiques déterministes, médiane + best sur N runs.
4. **Workflow CI `perf-bench.yml`** : build QGIS réel (config rapide avec
   Python) puis exécution de la suite dans l'image build-deps, tableau
   complet dans le résumé du run. Manuel uniquement.
5. **Profiling du build** : `qgis-fastbuild.sh --profile` (ninja -d stats),
   `--trace` (clang `-ftime-trace` + ClangBuildAnalyzer), `--graph`
   (graphe de dépendances ninja).

### Interface
6. **Recherche de projets récents sur l'écran d'accueil**
   (`src/app/qml/WelcomeScreen.qml`) : champ de recherche filtrant
   titre + chemin, ouverture en un clic, orphelins signalés. Volontairement
   **en lecture seule** : les menus contextuels des cartes restent
   index-mappés au modèle C++ (aucun risque de désynchronisation d'index).

### Écran d'accueil & onboarding (tours précédents, rappel)
7. Onglet « Learn », guide de premier lancement, bouton Documentation,
   action Projet ▸ Welcome Screen, thèmes Aurora/Aurora Light.

## 3. Feuille de route des goulots restants (priorisée, avec conditions de validation)

Classés par ratio gain/risque. **Aucun ne sera patché sans un environnement de
build + la suite de benchmarks ci-dessus** : c'est la politique d'intégrité du
fork.

| # | Cible | Gain attendu | Risque | Prérequis |
|---|---|---|---|---|
| R1 | Étiquetage PAL : limites de candidats auto-adaptatives en fonction du nombre de features visibles | rendu des vues denses 2–5× plus rapide | moyen (qualité du placement) | build + tests visuels de référence |
| R2 | Mémoïsation d'expressions **pures** (sans variables de contexte) dans les renderers catégorisés/gradués | faible-moyen | moyen (vérifier que le contexte n'influence pas le résultat) | build + tests unitaires expression |
| R3 | Préparation des requêtes raster COG (fenêtres de lecture alignées blocs) dans `QgsRasterDataProvider` | lecture raster distant nettement réduite | moyen | build + données COG réelles |
| R4 | Pré-fetch parallèle des pages de features dans la table attributaire pour les providers lents | tables distantes plus fluides | moyen (concurrence) | build + PostGIS de test |
| R5 | GPU (Qt6 RHI) pour le canvas 2D | gain incertain, dépend des cas | très élevé (réécriture) | chantier amont multi-mois — hors périmètre fork |

## 4. Ce que ce fork refuse délibérément de faire

- Modifier `src/core` sans build+tests (risque de régression inacceptable sur
  2,7 M lignes).
- Promettre des multiplicateurs de vitesse issus de benchmarks artificiels.
- Casser les API C++/Python publiques, les projets `.qgz` existants ou les
  plugins (toute l'interface publique reste intacte).
- Activer des comportements surprenants pour l'utilisateur (tous les défauts
  changés sont documentés et réversibles).
