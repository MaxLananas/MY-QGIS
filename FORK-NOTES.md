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

## 2. Thèmes « Aurora » (interface moderne)

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

## 3. Écran d'accueil : prise en main

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

## 4. Politique IA du projet amont

Le dépôt amont QGIS interdit les contributions assistées par IA (voir
`AGENTS.md` et la QEP-408). Ces modifications vivent uniquement dans ce fork :
**ne pas** proposer de pull request vers `qgis/QGIS` contenant ce code.
