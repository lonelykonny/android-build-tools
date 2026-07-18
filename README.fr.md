# 🔨 android-build-tools

**Compiler des APK Android en local sur ARM — natif Termux d'abord, proot + qemu en secours. Sans PC ni build cloud.**
> [🇬🇧 English](https://github.com/lonelykonny/android-build-tools/blob/master/README.md) • 🇫🇷 Français

Cette boîte à outils compile **n'importe quel projet Android/Gradle** (Android
natif, Capacitor, React Native, Flutter) directement sur un téléphone ARM. Elle
fournit aussi un petit serveur HTTP qui sert de back-end à l'application [APKforge](https://github.com/lonelykonny/APKforge).

[![Plateforme](https://img.shields.io/badge/plateforme-Termux%20%2F%20Android%20ARM-3DDC84)](https://img.shields.io/badge/plateforme-Termux%20%2F%20Android%20ARM-3DDC84) [![Méthode](https://img.shields.io/badge/aapt2-ARM%20natif%20(lzhiyong)-3DDC84)](https://img.shields.io/badge/aapt2-ARM%20natif%20(lzhiyong)-3DDC84) [![Shell](https://img.shields.io/badge/shell-bash-4EAA25)](https://img.shields.io/badge/shell-bash-4EAA25) [![Serveur](https://img.shields.io/badge/serveur-python3-3776AB)](https://img.shields.io/badge/serveur-python3-3776AB)

---

## Deux chaînes : le natif d'abord, le proot en secours

Cette boîte à outils propose **deux** façons de compiler. La chaîne **native** est celle par défaut ; la chaîne **proot + qemu** est un secours, installé et
utilisé seulement en cas de besoin.

| Chaîne            | Scripts                                                                                            | aapt2                                       | Vitesse             | Rôle                                                                 |
| ----------------- | -------------------------------------------------------------------------------------------------- | -------------------------------------------- | ------------------- | ---------------------------------------------------------------------- |
| **Termux-native** | `setup-termux-native.sh`, `build-termux-native.sh`                                                 | aapt2 ARM lzhiyong (natif)                  | rapide (natif)      | **par défaut** — chaque build démarre ici                            |
| **proot + qemu**  | `bootstrap-debian-build.sh`, `setup-aapt2-qemu.sh`, `android-builder.sh`, `build-android-local.sh` | aapt2 x86 de Google via qemu (proot Debian) | plus lente (émulée) | **secours** — seulement si le natif échoue pour une raison de chaîne |

Comment le serveur arbitre (`buildserver.py`) :

1. Chaque build est tenté **nativement** d'abord (aapt2 ARM natif, sans qemu).
2. S'il réussit → terminé. Rien d'autre n'est touché.
3. S'il échoue, le serveur regarde **pourquoi**. Une erreur de projet (erreur
   Kotlin, symbole manquant…) est rapportée telle quelle — le proot n'y
   changerait rien, donc pas de bascule.
4. Si l'échec est lié à la **chaîne** (p. ex. `failed to load include path .../android.jar` parce que la toolchain native ne peut pas satisfaire le compileSdk
   du projet), le serveur bascule sur la chaîne proot + qemu. Si aucun proot
   n'est encore installé, il **installe Debian à la demande** (`bootstrap-debian-build.sh`) puis réessaie dedans.

Pourquoi un secours ? Gradle a besoin d'`aapt2` pour lire l'`android.jar` de
l'API ciblée. L'aapt2 ARM natif utilisé ici provient de [lzhiyong](https://github.com/lzhiyong/termux-ndk) — recompilé depuis l'AOSP pour
aarch64 — et lit les `android.jar` récents (API 35/36), ce qui fait que la
plupart des projets, même en SDK récent, compilent en **natif** sans émulation.
La chaîne proot + qemu ne reste que pour les rares cas limites où la toolchain
d'un projet ne peut pas être satisfaite nativement (épinglage très précis d'une
version d'AGP/aapt2, ou outils pas encore disponibles en build aarch64).

**Effet net :** en pratique, presque tout compile vite et en natif, sans jamais
toucher de proot. Le secours Debian + qemu existe comme filet de sécurité et
n'est provisionné à la demande que si un build natif échoue pour une raison liée
à la chaîne.

## Le problème résolu

Gradle a besoin de l'outil **aapt2** pour compiler les ressources Android, et sur
un téléphone ARM non-rooté il n'existe pas de build officiel aarch64 des
build-tools Android récents.

**La solution native (par défaut) :** cette boîte à outils utilise des **build-tools aarch64 recompilés depuis l'AOSP par [lzhiyong](https://github.com/lzhiyong)** — un vrai `aapt2` ARM natif (ainsi que `aidl`, `zipalign`, etc.) qui tourne à pleine vitesse sans émulation et lit les `android.jar` récents. `setup-termux-native.sh` les télécharge et configure
Gradle pour utiliser l'`aapt2` natif via `android.aapt2FromMavenOverride`. C'est
ce qu'utilise chaque build.

**La solution de secours (qemu, historique) :** avant que ces build-tools natifs
ne soient disponibles, la seule façon d'avoir un `aapt2` récent sur ARM était
d'exécuter le binaire **x86** de Google via **qemu**. Cette chaîne est conservée
comme filet de sécurité. Deux subtilités la font fonctionner :

- `binfmt_misc` (exécution x86 transparente) est **absent** sur Android non-root :
  on ne peut pas simplement « lancer » le binaire x86, il faut appeler qemu
  explicitement.
- Gradle **refuse un script shell** comme aapt2 (il exige un vrai binaire ELF).
  On contourne avec un **shim** : un minuscule binaire ELF natif ARM qui ne fait
  que relancer `qemu + aapt2-x86`, injecté dans le `.jar` aapt2 que Gradle
  conserve en cache.

Chaîne de secours :

```
Gradle ──▶ (cache) aapt2 = SHIM (ELF ARM) ──▶ qemu-x86_64 ──▶ aapt2 x86 récent ──▶ lit android.jar
```

## Installation

Tout se pilote depuis **Termux** (aucun proot nécessaire en usage normal).

**Chaîne native (par défaut) :**

```
bash ~/android-build-tools/setup-termux-native.sh
```

Ceci installe **Python** (requis par `buildserver.py`), le JDK, le **SDK
Android aarch64** (aapt2 ARM natif + plateformes, depuis
[lzhiyong/termux-ndk](https://github.com/lzhiyong/termux-ndk)), remplace
les éventuels binaires build-tools x86 par leurs équivalents ARM natifs (depuis [lzhiyong/android-sdk-tools](https://github.com/lzhiyong/android-sdk-tools)), et
configure Gradle pour utiliser l'`aapt2` natif. Idempotent. Après ça, tu peux
compiler quasiment tout projet, y compris en compileSdk récent.

**Secours Debian (optionnel, à la demande) :**

Tu n'as normalement pas à l'installer toi-même — le serveur le provisionne
automatiquement la première fois qu'un build natif échoue pour une raison de
chaîne. Pour le mettre en place à l'avance malgré tout :

```
bash ~/android-build-tools/bootstrap-debian-build.sh
```

Ceci installe un proot Debian **minimal** et y lance `setup-aapt2-qemu.sh` (qemu, gcc, JDK, libs x86 multiarch, aapt2 x86, le shim, et une seule plateforme
SDK). Rien de superflu ; le proot reste au repos tant que les builds natifs
réussissent.

## Utilisation

### Compiler depuis une URL git (tout-en-un)

`android-builder.sh` clone un dépôt, **détecte son type** (Flutter / Capacitor /
React Native / Android natif), extrait ses besoins (compileSdk, AGP…), installe
les plateformes SDK manquantes, prépare (`npm install` / `cap sync` / `pub get`)
puis compile via la chaîne aapt2 + qemu.

```
# dans le proot Debian de secours (le serveur y entre automatiquement) :
proot-distro login debian
bash ~/android-build-tools/android-builder.sh https://github.com/utilisateur/projet
```

Options :

```
--branch <nom>     # compiler une branche précise
--subdir <chemin>  # le projet est dans un sous-dossier (monorepo)
--task <tâche>     # défaut : assembleDebug ; ex : assembleRelease
```

Si le build échoue, l'outil s'arrête et affiche un **diagnostic des causes
connues** plutôt que de tenter une correction à l'aveugle. Les dépôts clonés
sont placés dans `~/android-builds/<nom>`.

**Prérequis par type de projet :**

- **Capacitor / React Native** : `nodejs` + `npm` (`apt install -y nodejs npm`,
  ou via `setup-node.sh`).
- **Flutter** : le SDK Flutter doit être installé dans le proot Debian
  ([guide officiel](https://docs.flutter.dev/get-started/install/linux)).
  L'outil le détecte et prévient s'il manque.
- **Android natif** : rien de plus que la chaîne et le SDK Android.

### Compiler un projet déjà sur disque

```
proot-distro login debian
bash ~/android-build-tools/build-android-local.sh ~/mon-projet/android
```

- Projet **Capacitor** : viser le sous-dossier `android`.
- Projet **Android natif** : viser la racine (là où se trouve `gradlew`).
- Tâche par défaut : `assembleDebug`. Pour une autre :

```
bash ~/android-build-tools/build-android-local.sh ~/mon-projet/android assembleRelease
```

Le script patche le cache Gradle automatiquement, compile, et affiche le chemin
de l'APK. Pour le récupérer côté téléphone :

```
cp <chemin.apk> /data/data/com.termux/files/home/storage/downloads/
```

(nécessite `termux-setup-storage` exécuté une fois côté Termux.)

### Workflow Capacitor complet

Pour transformer une app web en APK :

```
# dans le dossier du projet, côté Debian :
npm install
npx cap sync android
bash ~/android-build-tools/build-android-local.sh ./android
```

### Serveur de build (back-end d'APKforge)

`buildserver.py` expose la chaîne via une petite API HTTP locale
(`127.0.0.1:8765`), pilotée par l'application [APKforge](https://github.com/lonelykonny/APKforge). Nécessite `python3`, installé par `setup-termux-native.sh`.

```
python3 ~/buildserver/buildserver.py        # ou : bash start-build-server.sh
```

Le serveur tourne **dans Termux**. Il pilote directement la chaîne native et,
uniquement sur un échec natif lié à la chaîne, provisionne puis utilise le
secours Debian + qemu (voir *Deux chaînes* plus haut).

### Build Termux-natif (voie par défaut)

Pour quasiment tous les projets, y compris en compileSdk récent, on compile en
natif dans Termux — pas de proot, pas de qemu, pleine vitesse native. À lancer **depuis Termux** (pas dans le proot) :

```
bash ~/android-build-tools/setup-termux-native.sh                 # une fois
bash ~/android-build-tools/build-termux-native.sh <url-git|chemin>  # build
```

`setup-termux-native.sh` installe Python, le JDK, le **SDK Android aarch64** et l'**aapt2
ARM natif** (depuis [lzhiyong/termux-ndk](https://github.com/lzhiyong/termux-ndk),
avec les build-tools de [lzhiyong/android-sdk-tools](https://github.com/lzhiyong/android-sdk-tools)), et
pointe Gradle dessus via `android.aapt2FromMavenOverride`. Il vérifie que le
binaire s'exécute vraiment (pas d'`Exec format error`). Cette chaîne native gère
le compileSdk récent, c'est donc la voie utilisée pour quasiment chaque build.

## Dépannage

**`Custom AAPT2 location does not point to an AAPT2 executable`** Un `aapt2FromMavenOverride` pointe sur le shim. Ne pas utiliser l'override : le
script passe par le patch du cache. Vérifier :

```
grep aapt2 ~/.gradle/gradle.properties   # ne doit RIEN afficher
```

**`failed to load include path .../android.jar` ou `LoadedArsc.cpp`** Le cache Gradle a été restauré avec l'aapt2 x86 d'origine (shim écrasé). Relancer
le build : le script re-patche automatiquement. Pour patcher à la main, voir la
fonction `patch_gradle_cache` dans `build-android-local.sh`.

**`SDK location not found`** Variable d'environnement perdue (nouveau shell). Le script recrée `local.properties` ; vérifier que `~/android-sdk` existe.

**`No cached version available for offline mode`** Ne pas lancer avec `--offline` au premier build d'un projet : Gradle doit
télécharger ses dépendances. Le script ne met pas `--offline` ; si on l'ajoute
manuellement, le retirer pour le premier build.

**`checkDebugAarMetadata ... requires compileSdk 36`** Une dépendance exige un compileSdk plus récent. Avec cette chaîne, on peut
simplement **monter le compileSdk** (le shim lit tous les jar) :

```
sdkmanager "platforms;android-36"
# puis ajuster compileSdk/targetSdk dans variables.gradle (Capacitor)
# ou build.gradle (Android natif)
```

**Version d'aapt2 / AGP différente** Le setup télécharge l'aapt2 `8.13.0-13719691` (= AGP 8.13). Si un projet utilise
un AGP très différent, Gradle voudra une autre version d'aapt2. Le shim lit
n'importe quel jar, mais le **nom de version** du jar de cache doit correspondre.
Le plus simple : aligner l'AGP du projet sur 8.13, ou éditer `AAPT2_VERSION` dans `setup-aapt2-qemu.sh` et le `:linux@jar` dans `build-android-local.sh`, puis
relancer le setup.

**`command not found: python3` au lancement du serveur** `setup-termux-native.sh` installe `python` ; si le serveur avait été mis en
place avant l'ajout de ce paquet, lance `pkg install -y python` une fois à la
main, ou relance `setup-termux-native.sh` (idempotent).

## Composants

| Élément              | Chemin                                    | Rôle                            |
| -------------------- | ----------------------------------------- | -------------------------------- |
| aapt2 x86 récent     | `~/aapt2-x86/aapt2`                       | le vrai outil, exécuté via qemu |
| shim ELF ARM         | `~/aapt2-shim`                            | pont Gradle → qemu              |
| source du shim       | `~/aapt2-shim.c`                          | pour recompiler si besoin       |
| backup jar d'origine | `~/.gradle/.../aapt2-*-linux.jar.x86.bak` | pour revenir en arrière         |

## Scripts du dépôt

| Script                        | Rôle                                                          |
| ----------------------------- | --------------------------------------------------------------- |
| `setup-termux-native.sh`      | installe la chaîne native (défaut : python, JDK, SDK, aapt2 natif) |
| `bootstrap-debian-build.sh`   | installe le proot Debian minimal de secours + la chaîne qemu  |
| `setup-aapt2-qemu.sh`         | installe la chaîne complète (qemu, aapt2 x86, shim)           |
| `android-builder.sh`          | clone depuis une URL git, détecte, prépare et compile         |
| `build-android-local.sh`      | patche le cache Gradle et compile un projet local             |
| `detect-project.sh`           | détecte le type de projet (Flutter/Capacitor/RN/natif)        |
| `patch-gradle-cache.sh`       | injecte le shim dans le jar aapt2 du cache Gradle             |
| `patch-native-buildtools.sh`  | patche aidl/zipalign/aapt/split-select x86 en ARM en cours de build si Gradle a installé une version x86 des build-tools |
| `stamp-version.sh`            | horodate versionName/versionCode pour que chaque build soit unique et installable par-dessus le précédent |
| `setup-node.sh`               | installe Node.js / npm pour les projets web                   |
| `build-termux-native.sh`      | compile en natif dans Termux (sans proot/qemu)                |
| `lib-i18n.sh`                 | messages de logs bilingues (EN par défaut, FR via `ABT_LANG`) |
| `buildserver.py`              | API HTTP locale, back-end de l'app APKforge (nécessite python3) |
| `start-build-server.sh`       | démarre le serveur de build                                   |

## Performances et limites

La voie **native** (aapt2 ARM lzhiyong) est la norme et tourne à pleine
vitesse. Le **secours** est un montage à plusieurs couches (Termux → proot →
qemu → shim → cache Gradle) : fonctionnel, mais qemu émule chaque instruction
d'aapt2, donc plus lent et plus fragile. Il n'intervient que dans les rares cas
où la toolchain native ne peut pas satisfaire un projet. Pour une CI rapide
et fiable, GitHub Actions reste l'option de référence ; cette boîte à outils
existe pour compiler **100 % en local**, y compris hors connexion.

## Crédits

La chaîne de build native n'est possible que grâce à **[lzhiyong](https://github.com/lzhiyong)**, qui recompile les outils du SDK
Android depuis l'AOSP pour aarch64. Cette boîte à outils télécharge et utilise
directement ses binaires précompilés :

- **[lzhiyong/termux-ndk](https://github.com/lzhiyong/termux-ndk)** — l'archive
  du SDK Android aarch64 (`android-sdk-aarch64.7z`) : `aapt2` ARM natif + les
  plateformes Android. C'est le cœur de la chaîne native.
- **[lzhiyong/android-sdk-tools](https://github.com/lzhiyong/android-sdk-tools)** — les build-tools aarch64 liés statiquement (`aidl`, `zipalign`, `aapt`,
  `split-select`, …), utilisés pour remplacer les éventuels binaires x86 que le
  SDK installerait. Compilés depuis l'AOSP ; à ce jour jusqu'à la release
  `35.0.2`.

Sans ça, compiler des APK Android en natif sur un téléphone ARM non-rooté ne
serait pas praticable. Tout le mérite de la partie difficile — porter les
build-tools sur ARM — revient à lzhiyong.

## Projets liés

- [APKforge](https://github.com/lonelykonny/APKforge) — l'interface Android qui pilote
  cette chaîne via le serveur HTTP.
