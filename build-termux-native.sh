#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# build-termux-native.sh
#
# Compile un projet Android en NATIF dans Termux (pas de proot/qemu).
# Necessite d'avoir lance setup-termux-native.sh une fois.
#
# Usage :
#   bash build-termux-native.sh <url-git> [--branch b] [--subdir d] [--task t]
#   bash build-termux-native.sh /chemin/projet/local   (chemin existant)
#
# Defaut : task = assembleDebug.
# =============================================================================
set -uo pipefail

_ABT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_ABT_DIR/lib-i18n.sh" ] && source "$_ABT_DIR/lib-i18n.sh"
type -t t >/dev/null 2>&1 || t() { printf '%s' "$1"; }

HOME_DIR="/data/data/com.termux/files/home"
ANDROID_HOME="$HOME_DIR/android-sdk"
BUILDS_DIR="$HOME_DIR/android-builds"

# Environnement natif.
export ANDROID_HOME
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(command -v java)")")}"

# Sortie Gradle en anglais (lisible a l'international), surchargee par --task FR sinon.
export LANG="${LANG:-en_US.UTF-8}"

SRC="${1:?Usage: build-termux-native.sh <url-git|chemin> [--branch b] [--subdir d] [--task t]}"
shift || true

BRANCH=""; SUBDIR=""; TASK="assembleDebug"
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2;;
    --subdir) SUBDIR="$2"; shift 2;;
    --task) TASK="$2"; shift 2;;
    *) shift;;
  esac
done

# Garde-fou : une valeur commencant par '-' pourrait etre interpretee comme une
# option par git (ex: une "URL" "--upload-pack=..." ferait executer une commande
# arbitraire via git clone). Aucune URL/branche/sous-dossier legitime ne
# commence par un tiret : on rejette ces valeurs plutot que de les transmettre
# telles quelles a git.
for _v in "$SRC" "$BRANCH" "$SUBDIR" "$TASK"; do
  case "$_v" in
    -*) echo "ERREUR: argument invalide (commence par '-'): $_v" >&2; exit 1 ;;
  esac
done

# --- 1. Resoudre le projet (URL git ou chemin local) -------------------------
if [ -d "$SRC" ]; then
  PROJECT_DIR="$SRC"
  printf "$(t local_project_step)\n" "$PROJECT_DIR"
else
  NAME="$(basename "${SRC%.git}")"
  DEST="$BUILDS_DIR/$NAME"
  mkdir -p "$BUILDS_DIR"
  if [ -d "$DEST/.git" ]; then
    echo "$(t already_cloned)"
    git -C "$DEST" checkout -q -- . 2>/dev/null || true  # annule l'horodatage precedent
    git -C "$DEST" fetch --all -q || true
    [ -n "$BRANCH" ] && git -C "$DEST" checkout -q "$BRANCH" || true
    git -C "$DEST" pull -q || true
  else
    printf "$(t clone_step)\n" "$SRC"
    if [ -n "$BRANCH" ]; then
      git clone -q --branch "$BRANCH" "$SRC" "$DEST"
    else
      git clone -q "$SRC" "$DEST"
    fi
  fi
  PROJECT_DIR="$DEST"
fi
[ -n "$SUBDIR" ] && PROJECT_DIR="$PROJECT_DIR/$SUBDIR"

# --- 1bis. Horodatage du versioning (versionName + versionCode) --------------
# Rend chaque build unique et installable par-dessus le precedent.
_STAMP_MODULE="${SUBDIR:-app}"
if [ -f "$_ABT_DIR/stamp-version.sh" ]; then
  bash "$_ABT_DIR/stamp-version.sh" "$PROJECT_DIR" "$_STAMP_MODULE" || true
fi

# --- 2. local.properties -----------------------------------------------------
if [ ! -f "$PROJECT_DIR/gradlew" ]; then
  printf "$(t no_gradlew_dir)\n" "$PROJECT_DIR"
  exit 1
fi
echo "sdk.dir=$ANDROID_HOME" > "$PROJECT_DIR/local.properties"

# --- 3. Build natif ----------------------------------------------------------
printf "$(t build_step)\n" "$TASK" "$PROJECT_DIR"
cd "$PROJECT_DIR"
chmod +x gradlew

# -Djava.security.egd=file:/dev/./urandom : sur Termux/proot, /dev/random peut
# manquer d'entropie et bloquer indefiniment la JVM des que SecureRandom est
# sollicite (typiquement la signature de l'APK, tache packageDebug). On force
# /dev/urandom (non bloquant) pour eviter un gel silencieux du build a ce stade.
GRADLE_EN_OPTS="-Duser.language=en -Duser.country=US -Djava.security.egd=file:/dev/./urandom"

# Garde-fou memoire pour mobile.
# Si GRADLE_JVMARGS est fourni (par l'app APKforge via buildserver.py, ou en
# variable d'env), on l'ecrit dans le gradle.properties GLOBAL (~/.gradle), qui
# a PRIORITE sur le gradle.properties du projet. Cela ecrase un -Xmx ambitieux
# (ex. Grit : -Xmx4096m) qui, sur telephone, fait tuer le process par Android
# ("Gradle build daemon disappeared unexpectedly"). Sans GRADLE_JVMARGS, on
# garde la valeur deja posee par setup-termux-native.sh.
if [ -n "${GRADLE_JVMARGS:-}" ]; then
  _GP="$HOME_DIR/.gradle/gradle.properties"
  mkdir -p "$(dirname "$_GP")"
  [ -f "$_GP" ] && sed -i '/^org.gradle.jvmargs/d' "$_GP"
  echo "org.gradle.jvmargs=$GRADLE_JVMARGS" >> "$_GP"
  echo "[server] heap Gradle force : $GRADLE_JVMARGS"
fi

# Limite le parallelisme pour borner le pic memoire (flag CLI fiable).
# Surchargeable via GRADLE_WORKERS (1 si la RAM est encore trop juste).
GRADLE_WORKERS="${GRADLE_WORKERS:-2}"

_gradle_log="$(mktemp)"
_cleanup_gradle_log() { rm -f "$_gradle_log"; }
trap _cleanup_gradle_log EXIT

run_gradle() {
  ./gradlew $GRADLE_EN_OPTS --max-workers="$GRADLE_WORKERS" "$TASK" --no-daemon 2>&1 | tee "$_gradle_log"
  return "${PIPESTATUS[0]}"
}

_print_diagnostics() {
  echo "$(t diag_header)"
  echo "  - aapt2 override absent/incorrect -> relance setup-termux-native.sh"
  echo "  - binaire build-tools x86 (aidl/zipalign 'Syntax error: word unexpected')"
  echo "    -> patch automatique tente ; si tu vois ce message, il a echoue"
  echo "       (verifie la connexion reseau, ou relance setup-termux-native.sh a la main)"
  echo "  - 'daemon disappeared' / build tue -> manque de RAM ; baisse la memoire"
  echo "    dans APKforge, ou reessaie avec GRADLE_WORKERS=1"
  echo "  - dependance exige compileSdk plus recent -> sdkmanager 'platforms;android-NN'"
}

if ! run_gradle; then
  # Cas cible : Gradle a installe EN COURS DE BUILD une version de build-tools
  # (ex. 36.0.0 exigee par le compileSdk du projet) dont les binaires aidl /
  # zipalign / aapt sont encore x86 -> "Syntax error: word unexpected" (shell
  # qui tente d'interpreter un ELF x86) ou "Exec format error". On patche et
  # on retente UNE fois avant d'abandonner.
  if grep -qiE "syntax error: word unexpected|exec format error" "$_gradle_log"; then
    echo "$(t build_retry)"
    echo "  -> binaire build-tools x86 detecte (aidl/zipalign/aapt), patch ARM et nouvel essai..."
    source "$_ABT_DIR/patch-native-buildtools.sh"
    if patch_native_buildtools && run_gradle; then
      : # succes au 2e essai, on continue normalement plus bas
    else
      _print_diagnostics
      exit 1
    fi
  else
    echo "$(t build_retry)"
    _print_diagnostics
    exit 1
  fi
fi

# --- 4. Localiser l'APK ------------------------------------------------------
echo
echo "=== $(t apk_produced) ==="
APK="$(find "$PROJECT_DIR" -path '*outputs/apk*' -name '*.apk' -print 2>/dev/null | head -n1)"
if [ -n "$APK" ]; then
  SIZE="$(stat -c%s "$APK" 2>/dev/null || echo '?')"
  echo "  $APK ($SIZE octets/bytes)"
  echo "$(t copy_to_dl)"
  echo "  cp \"$APK\" $HOME_DIR/storage/downloads/"
else
  printf "$(t no_apk)\n" "$TASK"
fi
echo "=== $(t build_success) ==="
