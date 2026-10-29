#!/usr/bin/env bash
#
# Construye el APK de bitra cebac contra el deploy de AWS, para instalar a mano
# en un teléfono. Imprime la ruta del APK:
#
#   ./build-apk.sh
#
# Sale firmado con el keystore debug y sólo para arm64-v8a: sirve para probar
# en teléfonos reales, no para la tienda. El nombre es bitra-cebac-<versión>-
# <sha corto>.apk, con -dirty-<hora> si el front tiene cambios sin commitear.
#
# Necesita el JDK 17 (con el 25 de Android Studio falla la CLI de Prefab):
# por defecto el ZIP portable de %LOCALAPPDATA%\Programs; otro, con JDK17_HOME.

set -euo pipefail
export MSYS_NO_PATHCONV=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && { pwd -W 2>/dev/null || pwd; })"
# shellcheck source=config.sh
source "$HERE/config.sh"
ROOT="$(cd "$HERE/../../.." && { pwd -W 2>/dev/null || pwd; })"

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

front_dir="$ROOT/lis-healthbook/lis-healthbook-front"
app_dir="$front_dir/apps/mobile"
out_dir="$ROOT/temp"

export JAVA_HOME="${JDK17_HOME:-$LOCALAPPDATA/Programs/jdk-17.0.20.1+1}"
export ANDROID_HOME="${ANDROID_HOME:-$LOCALAPPDATA/Android/Sdk}"
export PATH="$JAVA_HOME/bin:$PATH"

# Lo que el bundle de release inlinea. En la shell le gana al .env de la app,
# que queda apuntando al back local. La app es una sola para todos los
# laboratorios y los elige por slug; para este APK de prueba se la clava a
# CEBAC (sin selector) con el mismo mecanismo que el .env de desarrollo.
# El pool de Cognito ya no se inlinea: lo publica la API en /public/app-config.
export NODE_ENV=production
export EXPO_PUBLIC_API_URL="https://api.$DOMAIN/api/v1"
export EXPO_PUBLIC_WEB_URL="https://$DOMAIN"
export EXPO_PUBLIC_LAB_SLUG=cebac
export EXPO_PUBLIC_LAB_NAME="CEBAC Laboratorios"
export EXPO_PUBLIC_BITRA_CLIENT=cebac
export EXPO_PUBLIC_DEV_CODES=false

backup="$(mktemp -d)"
trap 'rm -rf "$backup"' EXIT

{
  cd "$app_dir"

  # El prebuild cambia los scripts android/ios de package.json y, al regenerar
  # android/, borra local.properties (el cmake.dir 3.31 del dev build).
  cp package.json "$backup/package.json"
  [ -f android/local.properties ] && cp android/local.properties "$backup/local.properties"

  npx expo prebuild --platform android --no-install

  cp "$backup/package.json" package.json
  if [ -f "$backup/local.properties" ]; then
    cp "$backup/local.properties" android/local.properties
  fi

  # Los módulos de node_modules/.pnpm dejan rutas de más de 260 caracteres
  # (prefab_command.bat, el .cxx de CMake) y CreateProcess y clang no aceptan
  # rutas largas aunque LongPathsEnabled esté prendido: el build y el .cxx de
  # esos módulos van a $ROOT/temp.
  cat >> android/build.gradle <<EOF

// build-apk.sh (lis-infra): rutas cortas para los módulos de node_modules.
subprojects { p ->
  if (p.projectDir.absolutePath.contains("node_modules")) {
    p.layout.buildDirectory = new File("$out_dir/ab", p.name)
    p.plugins.withId("com.android.library") {
      p.android.externalNativeBuild.cmake.buildStagingDirectory = new File("$out_dir/ac", p.name)
    }
  }
}
EOF

  cd android
  ./gradlew.bat assembleRelease -PreactNativeArchitectures=arm64-v8a --console=plain
  ./gradlew.bat --stop
} >&2

version=$(node -p "require('$app_dir/app.json').expo.version")
name="bitra-cebac-$version-$(git -C "$front_dir" rev-parse --short HEAD)"
if [ -n "$(git -C "$front_dir" status --porcelain)" ]; then
  name="$name-dirty-$(date +%Y%m%d%H%M)"
fi

mkdir -p "$out_dir"
cp "$app_dir/android/app/build/outputs/apk/release/app-release.apk" "$out_dir/$name.apk"

echo "$out_dir/$name.apk"
