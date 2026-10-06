#!/usr/bin/env bash
set -euo pipefail
# SDK_DIR points at a directory containing android-35/android.jar and build-tools.
android_project_dir="$(cd "$(dirname "$0")" && pwd)"
android_sdk_dir="${SDK_DIR:?Set SDK_DIR to your Android SDK directory}"
android_tools_dir="${BUILD_TOOLS_DIR:-$android_sdk_dir/build-tools/35.0.0}"
android_jar="$android_sdk_dir/android-35/android.jar"
android_build_dir="$android_project_dir/build"
mkdir -p "$android_build_dir/classes" "$android_build_dir/dex" "$android_build_dir/generated"
"$android_tools_dir/aapt2" compile --dir "$android_project_dir/res" -o "$android_build_dir/resources.zip"
"$android_tools_dir/aapt2" link -o "$android_build_dir/base.apk" --manifest "$android_project_dir/AndroidManifest.xml" -I "$android_jar" --java "$android_build_dir/generated" "$android_build_dir/resources.zip"
if command -v javac >/dev/null; then
 javac -source 8 -target 8 -cp "$android_jar" -d "$android_build_dir/classes" "$android_project_dir"/src/mw/sungira/app/*.java
else
 java -jar "${ECJ_JAR:?Install a JDK or set ECJ_JAR}" -8 -nowarn -bootclasspath "$android_jar:$android_tools_dir/core-lambda-stubs.jar" -d "$android_build_dir/classes" "$android_project_dir"/src/mw/sungira/app/*.java
fi
"$android_tools_dir/d8" --lib "$android_jar" --min-api 26 --output "$android_build_dir/dex" "$android_build_dir"/classes/mw/sungira/app/*.class
cp "$android_build_dir/base.apk" "$android_build_dir/unsigned.apk"
(cd "$android_build_dir/dex" && zip -q "$android_build_dir/unsigned.apk" classes.dex)
"$android_tools_dir/zipalign" -f 4 "$android_build_dir/unsigned.apk" "$android_build_dir/aligned.apk"
# Preview signing key. Replace with your own private production key before store distribution.
if [ ! -f "$android_project_dir/preview.keystore" ]; then
 keytool -genkeypair -keystore "$android_project_dir/preview.keystore" -storepass android -keypass android -alias androiddebugkey -dname 'CN=Sungira Preview,O=Sungira,C=MW' -keyalg RSA -keysize 2048 -validity 10000 -noprompt
fi
"$android_tools_dir/apksigner" sign --ks "$android_project_dir/preview.keystore" --ks-pass pass:android --key-pass pass:android --out "$android_project_dir/../downloads/sungira-preview.apk" "$android_build_dir/aligned.apk"
"$android_tools_dir/apksigner" verify --verbose "$android_project_dir/../downloads/sungira-preview.apk"
