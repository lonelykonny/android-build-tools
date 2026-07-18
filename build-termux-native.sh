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
  # Initialise/actualise les submodules Git (ex: metroproto pour Metrolist).
  # Un clone ou un pull normal ne recupere PAS le contenu des submodules : leur
  # dossier reste vide, ce qui casse silencieusement les etapes de generation
  # de code (protobuf, etc.) en aval et produit des erreurs de compilation
  # difficiles a relier a la vraie cause. On le fait systematiquement, meme
  # sur un repo deja clone (un submodule a pu etre ajoute depuis).
  if [ -f "$DEST/.gitmodules" ]; then
    echo "=== Initialisation des submodules Git ==="
    git -C "$DEST" submodule update --init --recursive -q || \
      echo "  ATTENTION: echec de l'initialisation des submodules (verifie le reseau)" >&2
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
  echo "  - fichier .proto/genere introuvable en cours de compilation -> submodule Git"
  echo "    non initialise (verifie .gitmodules du projet, ou relance ce script)"
  echo "  - protoc/outil telecharge tue par SIGSYS (exit 159) -> binaire glibc"
  echo "    generique bloque par le seccomp Android (clone3) ; patch automatique"
  echo "    tente vers l'equivalent natif Termux ; si tu vois ce message, il a echoue"
  echo "    (verifie que 'pkg install protobuf' fonctionne)"
}

# Remplace un ou plusieurs binaires "protoc" telecharges par le plugin Gradle
# protobuf (generiques glibc/Linux, non compiles pour Termux) par le protoc
# natif Termux. Ces binaires generiques utilisent des appels systeme (clone3,
# rseq) que le filtre seccomp impose par Android aux process d'application
# bloque -> le process meurt avec SIGSYS (exit 159) des son lancement. Les
# paquets Termux, compiles specifiquement pour cet environnement, n'ont pas
# ce probleme.
_patch_protoc_seccomp() {
  if ! command -v protoc >/dev/null 2>&1; then
    echo "  -> installation du protoc natif Termux (pkg install protobuf)..."
    pkg install -y protobuf || {
      echo "  echec: impossible d'installer 'protobuf' via pkg" >&2
      return 1
    }
  fi
  local native_protoc found=0 bin
  native_protoc="$(command -v protoc)"
  while IFS= read -r -d '' bin; do
    ln -sf "$native_protoc" "$bin"
    found=1
  done < <(find "$PROJECT_DIR" -type f -path '*/build/protoc/protoc-*' -print0 2>/dev/null)
  [ "$found" -eq 1 ]
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
  # Cas cible : un outil telecharge par Gradle (typiquement protoc du plugin
  # protobuf) est un binaire glibc generique tue par le seccomp Android des
  # son execution (SIGSYS / exit 159). On le remplace par l'equivalent natif
  # Termux et on retente UNE fois.
  elif grep -qiE "sigsys|exit value 159" "$_gradle_log"; then
    echo "$(t build_retry)"
    echo "  -> protoc/outil telecharge tue par SIGSYS (seccomp Android), bascule natif Termux et nouvel essai..."
    if _patch_protoc_seccomp && run_gradle; then
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
