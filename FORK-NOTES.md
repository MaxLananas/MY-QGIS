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

## 2. Builds ultra-rapides

QGIS est un monstre C++ (~2,7 M de lignes) : **un build complet à froid ne
pourra jamais durer 2 minutes** (comptez ~30–60 min, une seule fois). En
revanche, tout a été mis en place pour que **chaque rebuild après le premier
soit de l'ordre de quelques secondes à 2 minutes** :

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
