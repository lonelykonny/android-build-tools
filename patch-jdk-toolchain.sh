#!/data/data/com.termux/files/usr/bin/bash
# patch-jdk-toolchain.sh
#
# Detecte les JDK installes via pkg sous Termux et les declare a Gradle
# pour resoudre les erreurs :
#   "Cannot find a Java installation on your machine ... matching: {languageVersion=NN, ...}"
#   "Toolchain download repositories have not been configured."
#
# A placer dans le repo Pandarte/android-build-tools, aux cotes de
# patch-native-buildtools.sh (meme convention de nommage/structure).

patch_jdk_toolchain() {
    local project_dir="$1"
    local gradle_props="$project_dir/gradle.properties"

    local jdk_paths=()
    for d in "$PREFIX"/opt/openjdk-*; do
        [ -d "$d" ] && jdk_paths+=("$d")
    done

    if [ ${#jdk_paths[@]} -eq 0 ]; then
        echo "[patch] aucun JDK Termux trouve sous \$PREFIX/opt -> patch toolchain impossible"
        echo "[patch]   (essaie : pkg install openjdk-17)"
        return 1
    fi

    local paths_csv
    paths_csv=$(IFS=,; echo "${jdk_paths[*]}")

    touch "$gradle_props"
    # Retire une eventuelle ancienne entree pour eviter les doublons/conflits
    sed -i '/^org\.gradle\.java\.installations\.paths=/d' "$gradle_props"
    sed -i '/^org\.gradle\.java\.installations\.auto-download=/d' "$gradle_props"

    {
        echo "org.gradle.java.installations.paths=$paths_csv"
        echo "org.gradle.java.installations.auto-download=false"
    } >> "$gradle_props"

    echo "[patch] toolchain Java declaree dans gradle.properties : $paths_csv"
    return 0
}

# Permet d'appeler le script directement pour tester :
#   ./patch-jdk-toolchain.sh /chemin/vers/le/projet
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ -z "$1" ]; then
        echo "Usage: $0 <project_dir>" >&2
        exit 1
    fi
    patch_jdk_toolchain "$1"
fi
