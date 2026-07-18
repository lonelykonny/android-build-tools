#!/bin/bash
# =============================================================================
# android-builder.sh
# Compile un projet Android en local a partir de son URL git, sur ARM,
# via la chaine aapt2+qemu.
#
# Usage :
#   android-builder.sh <url-git> [--branch <nom>] [--subdir <chemin>] [--task <tache>]
#
# Exemples :
#   android-builder.sh https://github.com/lonelykonny/souffle-app
#   android-builder.sh https://github.com/x/y --branch dev --task assembleRelease
#   android-builder.sh https://github.com/x/monorepo --subdir apps/mobile
#
# Strategie (selon ton choix) : large couverture (Flutter / Capacitor /
# React Native / Android natif), tentative AUTOMATIQUE, et en cas d'echec
# de build -> diagnostic + on te demande quoi faire.
# =============================================================================

set -uo pipefail
# Charge les messages bilingues (EN par defaut, FR si ABT_LANG=fr).
_ABT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_ABT_DIR/lib-i18n.sh" ] && source "$_ABT_DIR/lib-i18n.sh"


HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/detect-project.sh"

# --- chargement de node/npm --------------------------------------------------
# Quand ce script est lance via 'proot-distro login ubuntu -- ...', le .bashrc
# n'est PAS charge : node/npm installes par nvm ne sont pas dans le PATH.
# Strategie en 3 temps (du plus fiable au secours) :
#   1) /usr/local/bin (symlinks crees a l'install) est deja dans le PATH systeme
#   2) on charge nvm explicitement
#   3) en dernier recours on ajoute a la main le bin de la version nvm la + recente
export PATH="/usr/local/bin:$PATH"
if [ -s "$HOME/.nvm/nvm.sh" ]; then
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
fi
if ! command -v node >/dev/null 2>&1; then
    NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
    [ -n "${NODE_BIN:-}" ] && export PATH="$NODE_BIN:$PATH"
fi

# --- parse args --------------------------------------------------------------
URL="${1:?Usage: android-builder.sh <url-git> [--branch b] [--subdir d] [--task t]}"
shift || true
BRANCH=""; SUBDIR=""; TASK="assembleDebug"
while [ $# -gt 0 ]; do
    case "$1" in
        --branch) BRANCH="$2"; shift 2;;
        --subdir) SUBDIR="$2"; shift 2;;
        --task)   TASK="$2"; shift 2;;
        *) echo "Option inconnue: $1"; exit 1;;
    esac
done

# Garde-fou : une valeur commencant par '-' pourrait etre interpretee comme une
# option par git (ex: une "URL" "--upload-pack=..." ferait executer une commande
# arbitraire via git clone). Aucune URL/branche/sous-dossier legitime ne
# commence par un tiret : on rejette ces valeurs plutot que de les transmettre
# telles quelles a git.
for _v in "$URL" "$BRANCH" "$SUBDIR" "$TASK"; do
    case "$_v" in
        -*) echo "ERREUR: argument invalide (commence par '-'): $_v" >&2; exit 1 ;;
    esac
done

WORK="$HOME/android-builds"
mkdir -p "$WORK"
NAME="$(basename "$URL" .git)"
DEST="$WORK/$NAME"
ANDROID_SDK="$HOME/android-sdk"
SHIM_BIN="$HOME/aapt2-shim"

# --- 0. pre-checks -----------------------------------------------------------
if [ ! -x "$SHIM_BIN" ]; then
    echo "$(t chain_missing)"
    echo "    bash $HERE/setup-aapt2-qemu.sh"
    exit 1
fi
command -v git >/dev/null || { apt-get update -y && apt-get install -y git; }

export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(which java)")")")"
export ANDROID_HOME="$ANDROID_SDK"
export PATH="$ANDROID_SDK/cmdline-tools/latest/bin:$ANDROID_SDK/platform-tools:$PATH"

# --- 1. clone ----------------------------------------------------------------
printf "$(t clone_step)\n" "$URL"
if [ -d "$DEST/.git" ]; then
    echo "$(t already_cloned)"
    git -C "$DEST" checkout -q -- . 2>/dev/null || true  # annule l'horodatage precedent
    git -C "$DEST" pull --ff-only || echo "(pull ignore)"
else
    if [ -n "$BRANCH" ]; then
        git clone --depth 1 --branch "$BRANCH" "$URL" "$DEST"
    else
        git clone --depth 1 "$URL" "$DEST"
    fi
fi
ROOT="$DEST"
[ -n "$SUBDIR" ] && ROOT="$DEST/$SUBDIR"
[ -d "$ROOT" ] || { printf "$(t subdir_missing)\n" "$SUBDIR"; exit 1; }

# --- 1bis. Horodatage du versioning (versionName + versionCode) --------------
# Rend chaque build unique et installable par-dessus le precedent.
if [ -f "$_ABT_DIR/stamp-version.sh" ]; then
    bash "$_ABT_DIR/stamp-version.sh" "$ROOT" "${SUBDIR:-app}" || true
fi

# --- 2. detection ------------------------------------------------------------
echo "$(t detect_step)"
TYPE="$(detect_project_type "$ROOT")"
printf "$(t type_detected)\n" "$TYPE"
if [ "$TYPE" = "unknown" ]; then
    echo "$(t type_unknown)"
fi

GRADLE_DIR="$(find_gradle_dir "$ROOT" "$TYPE")"
printf "$(t android_module)\n" "${GRADLE_DIR:-<none>}"

# besoins
COMPILE_SDK="$(extract_sdk "$ROOT" compileSdk)"
TARGET_SDK="$(extract_sdk "$ROOT" targetSdk)"
MIN_SDK="$(extract_sdk "$ROOT" minSdk)"
AGP="$(extract_agp "$ROOT")"
printf "$(t needs_extracted)\n" "${COMPILE_SDK:-?}" "${TARGET_SDK:-?}" "${MIN_SDK:-?}" "${AGP:-?}"

# avertissement version aapt2 vs AGP
SHIM_AGP="8.13"
if [ -n "$AGP" ] && [[ "$AGP" != $SHIM_AGP* ]]; then
    printf "$(t agp_note)\n" "$AGP" "$SHIM_AGP"
    echo "$(t agp_note2)"
fi

# --- 3. installation des plateformes SDK requises ----------------------------
echo "$(t sdk_install_step)"
if [ -d "$ANDROID_SDK" ]; then
    for sdk in $(list_required_sdks "$ROOT"); do
        if [ ! -d "$ANDROID_SDK/platforms/android-$sdk" ]; then
            echo "  -> platforms;android-$sdk"
            yes | sdkmanager "platforms;android-$sdk" >/dev/null 2>&1 || \
                printf "$(t sdk_install_fail)\n" "$sdk"
        fi
    done
else
    printf "$(t sdk_absent)\n" "$ANDROID_SDK"
fi

# --- 4. preparation selon le type --------------------------------------------
printf "$(t prepare_step)\n" "$TYPE"
prepare_failed=0

# pour capacitor/react-native, node est indispensable
case "$TYPE" in
    capacitor|react-native)
        if ! command -v node >/dev/null 2>&1; then
            echo "$(t node_missing)"
            echo "$(t install_once)"
            echo "    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
            echo "    export NVM_DIR=\"\$HOME/.nvm\"; . \"\$NVM_DIR/nvm.sh\"; nvm install 20"
            echo "    ln -sf \"\$(which node)\" /usr/local/bin/node"
            echo "    ln -sf \"\$(which npm)\"  /usr/local/bin/npm"
            echo "    ln -sf \"\$(which npx)\"  /usr/local/bin/npx"
            prepare_failed=1
        else
            echo "node $(node --version), npm $(npm --version)"
        fi
        ;;
esac

if [ "$prepare_failed" = 0 ]; then
case "$TYPE" in
    capacitor)
        # npm install (deps locales, dont @capacitor/cli local si present),
        # puis sync des assets web vers le projet android.
        ( cd "$ROOT" && npm install ) || prepare_failed=1
        if [ "$prepare_failed" = 0 ]; then
            # essaie le cap local du projet, sinon le cap global
            ( cd "$ROOT" && npx cap sync android ) \
                || ( cd "$ROOT" && cap sync android ) \
                || echo "$(t cap_sync_fail)"
        fi
        ;;
    react-native)
        ( cd "$ROOT" && npm install ) || prepare_failed=1
        ;;
    flutter)
        if command -v flutter >/dev/null; then
            ( cd "$ROOT" && flutter pub get ) || prepare_failed=1
        else
            echo "$(t flutter_missing)"
            echo "$(t flutter_install)"
            echo "$(t flutter_install2)"
            prepare_failed=1
        fi
        ;;
    android-native|unknown)
        echo "$(t no_prepare)"
        ;;
esac
fi

if [ "$prepare_failed" = 1 ]; then
    echo
    echo "$(t prepare_failed)"
    echo "$(t prepare_failed2)"
    echo "$(t prepare_failed3)"
    echo "$(t prepare_failed4)"
    exit 2
fi

# --- 5. build via la chaine locale -------------------------------------------
echo "$(t build_step5)"
if [ "$TYPE" = "flutter" ] && command -v flutter >/dev/null; then
    # Flutter pilote Gradle lui-meme ; on patche le cache puis flutter build.
    "$HERE/patch-gradle-cache.sh" || true
    ( cd "$ROOT" && flutter build apk --debug )
    BUILD_RC=$?
else
    # Capacitor / RN / natif : on delegue a build-android-local.sh
    if [ -z "$GRADLE_DIR" ]; then
        echo "$(t no_gradlew)"
        exit 2
    fi
    bash "$HERE/build-android-local.sh" "$GRADLE_DIR" "$TASK"
    BUILD_RC=$?
fi

# --- 6. resultat / diagnostic ------------------------------------------------
echo
if [ "${BUILD_RC:-1}" -eq 0 ]; then
    echo "$(t build_success_hdr)"
    find "$ROOT" -path '*outputs*' -name '*.apk' -printf '  %p  (%s octets)\n' 2>/dev/null
    echo
    echo "$(t copy_to_dl_label)"
    echo "  cp <chemin.apk> /data/data/com.termux/files/home/storage/downloads/"
else
    printf "$(t build_failed_hdr)\n" "$BUILD_RC"
    echo "$(t diag_header)"
    LOG="$ROOT/build/reports/problems/problems-report.html"
    echo "$(t diag_arsc)"
    echo "$(t diag_arsc2)"
    echo "$(t diag_compilesdk)"
    echo "$(t diag_compilesdk2)"
    echo "$(t diag_vanilla)"
    echo "$(t diag_vanilla2)"
    echo "$(t diag_sdkloc)"
    echo
    echo "$(t show_exact_error)"
    echo "$(t decide_fix)"
fi
exit "${BUILD_RC:-1}"
