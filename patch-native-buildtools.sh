#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# patch-native-buildtools.sh
#
# Patche en ARM64 tout binaire x86 present dans build-tools/*/ (aidl,
# zipalign, aapt, split-select). Extrait de setup-termux-native.sh pour etre
# reutilisable :
#   - au setup initial (setup-termux-native.sh)
#   - en retry automatique post-echec (build-termux-native.sh), quand Gradle
#     a installe EN COURS DE BUILD une nouvelle version de build-tools
#     (ex. 36.0.0 exigee par un compileSdk recent) qui n'a jamais ete patchee.
#
# lzhiyong/android-sdk-tools ne fournit des binaires ARM que jusqu'a
# BT_ARM_RELEASE. Pour une version de build-tools plus recente, on reutilise
# quand meme ces memes binaires : aidl/zipalign/aapt changent tres peu d'une
# version a l'autre (contrairement a aapt2, deja gere a part via
# android.aapt2FromMavenOverride, qui lui EST sensible a la version exacte).
#
# Usage : source ce fichier puis appelle patch_native_buildtools
#   source patch-native-buildtools.sh
#   patch_native_buildtools
# Necessite ANDROID_HOME (ou HOME_DIR) deja exporte par le script appelant.
# =============================================================================

HOME_DIR="${HOME_DIR:-/data/data/com.termux/files/home}"
ANDROID_HOME="${ANDROID_HOME:-$HOME_DIR/android-sdk}"

# Liste ciblee : on NE patche QUE ce qui est utile et invoque en pratique.
# - aidl        : compilation des interfaces AIDL (.aidl)
# - zipalign    : alignement de l'APK (quasi tous les builds)
# - aapt        : ancien AAPT, encore appele par des projets/plugins legacy
# - split-select: APK splits (ABI/density)
# Ignores volontairement : aapt2 (override ARM separe), d8/apksigner/lld
# (scripts JVM, pas natifs), bcc_compat/llvm-rs-cc/dexdump (RenderScript mort
# ou outils de debug jamais dans la chaine de build).
BT_PATCH_TOOLS="${BT_PATCH_TOOLS:-aidl zipalign aapt split-select}"
BT_ARM_RELEASE="${BT_ARM_RELEASE:-35.0.2}"
BT_ARM_ASSET="android-sdk-tools-static-aarch64.zip"
BT_ARM_URL="https://github.com/lzhiyong/android-sdk-tools/releases/download/$BT_ARM_RELEASE/$BT_ARM_ASSET"

# Detecte si un fichier est un ELF ARM aarch64 SANS dependre de `file`
# (souvent absent sur Termux). Lit le magic ELF puis e_machine (0xB7=AArch64).
is_arm64() {
  local f="$1"
  [ -f "$f" ] || return 1
  local magic mach
  magic="$(head -c4 "$f" | od -An -tx1 | tr -d ' \n')"
  [ "$magic" = "7f454c46" ] || return 1
  mach="$(dd if="$f" bs=1 skip=18 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ "$mach" = "b7" ]
}

# Parcourt toutes les versions de build-tools installees et patche celles qui
# sont encore x86. Renvoie :
#   0 = ok (au moins un binaire patche, ou rien a faire)
#   1 = un patch etait requis mais le telechargement de l'archive ARM a echoue
patch_native_buildtools() {
  local BT_ROOT="$ANDROID_HOME/build-tools"
  local _need_patch=""

  if [ ! -d "$BT_ROOT" ]; then
    echo "  Aucun build-tools installe, rien a patcher."
    return 0
  fi

  local _btdir _tool _tp _src _tmp_arm
  for _btdir in "$BT_ROOT"/*/; do
    for _tool in $BT_PATCH_TOOLS; do
      _tp="$_btdir$_tool"
      [ -f "$_tp" ] || continue
      if ! is_arm64 "$_tp"; then
        _need_patch="yes"
      fi
    done
  done

  if [ -z "$_need_patch" ]; then
    echo "  Tous les binaires cibles sont deja ARM (ou absents). Rien a patcher."
    return 0
  fi

  _tmp_arm="$(mktemp -d)"
  echo "  Telechargement des build-tools ARM64 ($BT_ARM_RELEASE)..."
  if ! wget -q -O "$_tmp_arm/arm.zip" "$BT_ARM_URL"; then
    echo "  ! Telechargement des build-tools ARM echoue ($BT_ARM_URL)."
    rm -rf "$_tmp_arm"
    return 1
  fi
  ( cd "$_tmp_arm" && 7z x -y arm.zip >/dev/null 2>&1 || unzip -q arm.zip )

  for _btdir in "$BT_ROOT"/*/; do
    for _tool in $BT_PATCH_TOOLS; do
      _tp="$_btdir$_tool"
      [ -f "$_tp" ] || continue
      is_arm64 "$_tp" && continue  # deja ARM, on saute

      _src="$(find "$_tmp_arm" -type f -name "$_tool" | head -n1)"
      if [ -z "$_src" ] || ! is_arm64 "$_src"; then
        echo "  ! $_tool : introuvable dans l'archive $BT_ARM_RELEASE, ignore."
        continue
      fi

      [ -f "$_tp.x86.bak" ] || cp -p "$_tp" "$_tp.x86.bak"
      cp "$_src" "$_tp" && chmod +x "$_tp"
      echo "  OK $_tool patche ARM dans $(basename "$_btdir") (source: build-tools $BT_ARM_RELEASE)"
    done
  done
  rm -rf "$_tmp_arm"
  return 0
}
