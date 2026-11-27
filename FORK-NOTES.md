# Notes du fork « MY-QGIS »

Ce fichier résume les personnalisations apportées à ce fork par rapport au QGIS
officiel (branche `master` amont). Il n'existe pas en amont.

## 1. GitHub Actions : plus aucun artefact

Les builds QGIS produisent des fichiers de plusieurs Go (bundles Windows/macOS,
SDK vcpkg, archives de build). Les uploader sur chaque exécution épuise très
vite le quota de stockage GitHub Actions. Tout a donc été retiré :

- **Aucun** `actions/upload-artifact` ne subsiste dans `.github/workflows/` ;
  plus rien n'occupe le stockage d'artefacts.
- Les jobs qui ne servaient qu'à consommer ces artefacts ont été supprimés
  (création du dmg macOS, clang-tidy, commentaires de téléchargement sur les
  PR) ainsi que les deux workflows de commentaires
  (`build_artifact_comment.yml`, `write_failure_comment.yml`).
- Les workflows très lourds sont désormais **manuels uniquement** :
  - 🪟 `windows-qt6.yml`, 🍎 `build-macos-qt6.yml`, 🦊 `wasm.yml` →
    bouton « Run workflow » uniquement ;
  - 🧪 `run-tests.yml` et 🗺 `ogc.yml` → `workflow_dispatch` + `pull_request`
    (plus de build Docker automatique à chaque push).

Pour réactiver un déclencheur automatique, remettez simplement le bloc `on:`
souhaité en tête du fichier de workflow concerné.

## 2. Builds ultra-rapides — architecture mesurée

### Le verdict physique, sans fard

QGIS ≈ 2 600 unités de compilation C++ avec des headers très lourds
 Qt inclus) : **un build complet depuis les sources ne sera jamais < 120 s**
sur du matériel standard. Le "24 h" constaté venait d'ailleurs : runners
« blacksmith » payants non configurés (jobs bloqués indéfiniment — corrigé),
installations vcpkg, builds Docker automatiques. Tout cela est neutralisé.

En revanche, l'**architecture à 3 niveaux ci-dessous rend le pire cas rare et
le cas courant très rapide** — chaque affirmation est adossée à une mesure
réelle (voir « Benchmarks »).

### Architecture de cache à 3 niveaux

| Niveau | Contenu | Effet |
|---|---|---|
| **L1** | arbre de build persistant (`build-fast/`) restauré en CI | ninja ne recompile **que le diff** + lien mold → chemin < 120 s |
| **L2** | ccache (ou sccache opt-in) | si L1 est évincé : rebuild complet depuis le cache, pas depuis les sources |
| **L3** | image Docker `build-deps` précompilée par le projet QGIS | zéro compilation de dépendances, jamais |

### Benchmarks mesurés (corpus synthétique calibré QGIS : 600 TU, headers
lourds, 3 bibliothèques, lot unity de 8 — harnais : `scripts/bench-build.sh`)

Exécutés réellement (gcc 12 / ninja 1.13 / ccache 4.11, 2 cœurs) :

| Scénario | Mesuré | Gain |
|---|---|---|
| A — build froid, unity OFF, PCH OFF, `-g1` | **120,8 s** | baseline |
| A2 — build froid, debug complet `-g` | **135,5 s** | `-g1` fait gagner **12 %** |
| B — froid, unity ON | **22,8 s** | **5,3×** |
| C — froid, unity + PCH (le réglage « fast ») | **15,5 s** | **7,8×** |
| D3 — wipe des .o + rebuild complet via ccache, **même dossier** | **0,5 s** | ~100 % de hits |
| G — no-op ninja (rien changé) | **0,1 s** | |
| E/F — incrémental 1 TU édité | **0,6–0,9 s** | |

**Découverte mesurée (risque PCH/cccache)** : un rebuild complet depuis le
cache dans un **dossier différent** donne **0 % de hits même avec
`hash_dir=false`** (D1/D2 = 15,5 s ≈ recompilation complète) : le chemin
absolu du PCH (`-include …/cmake_pch.hxx`) fait partie de la clé de cache.
Mitigation appliquée partout : **chemin de build fixe** — conteneur CI
`/root/QGIS/build-fast` (identique à chaque run) et local
`${SOURCE_DIR}/build-fast`. Déplacer un arbre de build = ressaisir le cache.

Mise à l'échelle honnête vers QGIS (~2 600 TU, TUs ~2–3× plus lourds) :
froid ≈ 20–25 min sur 2 cœurs (≈ 3–5 min sur 16 cœurs) **une fois** ;
ensuite : incrémental CI ≈ compiles du diff + lien mold (objectif < 120 s) ;
no-op ≈ secondes. Le lien final reste le poste dominant en incrémental —
d'où mold (les benchmarks publiés du dépôt mold montrent des liens de
grands binaires passant de minutes à secondes).

### ccache vs sccache (choix argumenté)

| Critère | ccache (défaut) | sccache (opt-in) |
|---|---|---|
| Intégration cache Actions | archive tar + restore (latence GB) | **service de cache Actions natif** (pas de tarball) |
| Mode PCH | documenté dans le man (`ccache(1)`), rodé | supporte mais moins éprouvé |
| Hachage | contenu, direct+preprocesseur, vérifié | contenu |
| Compilation distribuée | non | oui, mais **requiert une infrastructure** (scheduler + workers) → écarté (aucune dépense) |
| MSVC | ccache limité | bon |

→ `ccache` par défaut (robustesse PCH, intégrité documentée), `sccache`
activable d'un clic dans le workflow (backends S3/R2 possibles plus tard si
tu fournis un bucket — hors périmètre gratuit actuel).

### Approches explorées puis écartées (avec raison)

- **distcc / Icecream / sccache distributed** : compilation distribuée
  réelle = machines dédiées ou runners supplémentaires → payant. Écarté.
- **Clang modules C++20** : non supportés par ccache, immatures côté
  CMake/Qt → écartés.
- **ThinLTO** : améliore le produit final, pas la vitesse de développement ;
  dégrade les builds incrémentaux → réservé au release, pas au fast path.
- **PCH « maison » additionnels** : QGIS a déjà ses PCH par cible
  (`qgis.h`) ; ajouter des super-PCH modifierait le code amont pour un gain
  marginal après unity+PCH → écarté.
- **Runners 16 cœurs** : facturés même sur dépôt public (doc GitHub) →
  disponibles en option dans le workflow, jamais en défaut.

### Outils livrés

- `scripts/bench-build.sh` : le harnais de benchmark complet (A→H), exécutable
  partout où cmake/ninja/ccache existent ; résultats dans
  `build-bench/REPORT.txt` (hors Git).
- `scripts/qgis-fastbuild.sh` :
  - `--profile` : `ninja -d stats` + timings par étape ;
  - `--trace` : `-ftime-trace` clang par TU + ClangBuildAnalyzer si installé
    (voir messages du script) ;
  - `--graph` : graphe de dépendances ninja (dot) + entrées de la cible ;
  - `--doctor` : audit complet de l'environnement.
- `.github/workflows/fast-build.yml` v3 : scénarios `incremental` /
  `warm-cache` / `cold` mesurés en CI, choix du backend de cache et du
  runner, résumé de timing dans l'onglet Summary.

### Sur GitHub Actions

Workflow **🚀 Fast build** (bouton « Run workflow » uniquement — 0 minute
consommée sinon) : L1+L2 restaurés par défaut (`incremental`), image L3
précompilée, ccache réglé selon `ccache(1)`, mold, `-g1`, unity. Les
workflows Windows/macOS sont passés des runners « blacksmith » aux runners
GitHub standard. `vcpkg-bump` (cron hebdo) et `sipify-bot` s'auto-excluent
déjà sur le fork (`if: github.repository == 'qgis/QGIS'`) — vérifié.

### En local

```bash
./scripts/qgis-fastbuild.sh          # build la cible 'qgis' (app complète)
./scripts/qgis-fastbuild.sh qgis_gui # rebuild d'une seule bibliothèque
QGIS_FAST_PRESET=fast-python ./scripts/qgis-fastbuild.sh   # avec Python
```

Tous les leviers sont enfoncés en même temps :

- **Ninja** + **ccache** : ce qui n'a pas changé n'est pas recompilé ;
- **ccache réglé selon le manuel officiel** (`ccache(1)`) :
  `sloppiness=pch_defines,time_macros,include_file_mtime,include_file_ctime`
  (exigence documentée pour les en-têtes précompilés),
  `hash_dir=false` (le cache survit à un déplacement du dossier de build :
  autre chemin de clone, conteneur CI…), `compiler_check=content`,
  `inode_cache` quand le ccache le supporte. `depend_mode` est volontairement
  **écarté** : le manuel documente un taux de hit inférieur en échange —
  contre-productif ici ;
- **Unity builds** (`ENABLE_UNITY_BUILDS=ON`) : plusieurs .cpp par unité de
  compilation (lots de 8, défaut CMake) → beaucoup moins d'invocations du
  compilateur ;
- **En-têtes précompilés** (`USE_PRECOMPILED_HEADERS`, déjà fourni par QGIS)
  + **info de debug allégée `-g1`** (tables de lignes uniquement, GCC/Clang
  uniquement) : objets plus petits, compilations et liens plus rapides ;
- **linker `mold`** (auto-détecté, sinon `lld`) : l'édition de liens finale
  passe de minutes à secondes ;
- **Ensemble de fonctionnalités minimal** via `CMakeUserPresets.json`
  (`cmake --preset fast`) : pas de Python, serveur, GRASS, Oracle, HANA,
  PDAL, EPT, 3D, QtWebEngine, Wayland, QtSerialPort, tests ni doc API ;
- **Cible unique** : on ne build que `qgis`, pas « all ».

Presets disponibles : `fast` (Debug, sans Python — le plus rapide),
`fast-python` (Debug + Python), `fast-release` (Release + Python).
Les variantes Python conservent la toolbox Processing et les plugins.
Astuce : après modification d'un .cpp isolé, le rebuild est quasi instantané
(quelques secondes + link). Modifier un en-tête central reste plus coûteux —
c'est une limite physique du C++.

Le script a aussi deux modes utilitaires :

```bash
./scripts/qgis-fastbuild.sh --doctor   # audit de l'environnement (outils, cache, presets)
./scripts/qgis-fastbuild.sh --clean    # repart de zéro
```

### Sur GitHub Actions

Nouveau workflow manuel **🚀 Fast build** (`fast-build.yml`, bouton
« Run workflow » uniquement, donc 0 minute consommée tant que tu ne le
lances pas) :

- réutilise l'image Docker `build-deps` **déjà publiée par le projet QGIS**
  (plus de 40 min de préparation d'image gagnées ; bascule sur un build
  local si l'image n'est pas disponible) ;
- ccache « roulant » restauré à chaque run : seul le diff depuis le dernier
  run est recompilé ;
- build de la seule cible `qgis` avec unity + mold + `-g1` ;
- choix du preset (`fast`, `fast-python`, `fast-release`) et du runner au
  lancement. Par défaut : runner standard **gratuit** ; les runners «
  -N-cores » accélèrent le build à froid mais sont **facturés même sur les
  dépôts publics** (règle GitHub documentée) — à réserver aux runs où le
  temps compte ;
- résumé du temps de build + hit-rate ccache dans l'onglet « Summary ».

À noter aussi : les workflows manuels Windows et macOS sont passés des
runners « blacksmith » (service payant non configuré sur ce fork, les jobs
resteraient bloqués) aux runners GitHub standard inclus dans les repos
publics.

**Sources officielles consultées** : man `ccache(1)` (modes, sloppiness, PCH,
`hash_dir`), manuel Ninja (parallélisme), docs CMake
(`UNITY_BUILD_BATCH_SIZE`, presets), dépôt mold (performance de link),
documentation GitHub Actions (runners et facturation).

## 3. Thèmes « Aurora » (interface moderne)

Deux nouveaux thèmes installés dans `resources/themes/` :

- **Aurora** (sombre) : surfaces bleu-charbon, accent bleu `#3574f0`, plus
  aucun dégradé, coins arrondis (champs, boutons, menus, info-bulles, barres
  de progression), barres de défilement fines et discrètes, soulignement
  d'accent sur les onglets actifs, texte blanc sur sélection, palette Qt et
  couleurs de l'éditeur de code (qscintilla) assorties.
- **Aurora Light** (clair) : surfaces blanches sur gris clair froid, même
  accent et même modernisation.

**Aurora est le thème par défaut du fork** pour les nouvelles installations et
les personnes qui n'avaient jamais choisi de thème ; les choix existants
(`UI/UITheme`) sont conservés. Changement de thème à tout moment :
*Préférences ▸ Général ▸ Thème* (redémarrage nécessaire).

## 4. Écran d'accueil : prise en main

- Nouvel onglet **« Learn »** : parcours « Démarrez en cinq minutes »
  (créer un projet, ajouter des données, styliser, sauvegarder) avec boutons
  d'action directs, pense-bête des raccourcis essentiels et liens vers le
  manuel, les tutoriels, les nouveautés, l'aide communautaire, la fenêtre des
  raccourcis clavier et le signalement de bugs.
- **Premier lancement** : l'écran d'accueil s'ouvre directement sur l'onglet
  Learn et affiche une carte « New to QGIS? » (une seule fois, réglable via
  le paramètre `app/first-run-guide-done`).
- Bouton **Documentation** dans le pied de page de l'accueil.
- Nouvelle action **Projet ▸ Welcome Screen** pour rouvrir l'écran d'accueil
  à tout moment depuis la fenêtre principale.

## 5. Politique IA du projet amont

Le dépôt amont QGIS interdit les contributions assistées par IA (voir
`AGENTS.md` et la QEP-408). Ces modifications vivent uniquement dans ce fork :
**ne pas** proposer de pull request vers `qgis/QGIS` contenant ce code.
