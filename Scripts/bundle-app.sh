#!/bin/bash
# Builds "Owlink.app" from the SwiftPM CedricApp target. Command Line Tools
# only: no Xcode project, no asset catalog, no actool. Same shape as
# Tankard's bundle-app.sh.
#
#   Scripts/bundle-app.sh                 host architecture, ad-hoc signed
#   Scripts/bundle-app.sh --universal     x86_64 + arm64 in one binary
#   Scripts/bundle-app.sh --arch x86_64   one specific architecture
#   Scripts/bundle-app.sh --no-sign       leave it unsigned
#   Scripts/bundle-app.sh --out DIR       where "Owlink.app" goes (default: dist)
#   Scripts/bundle-app.sh --release       a release build: no dev/check switches
#
# By default this is a CHECK build: it compiles with CEDRIC_CHECKS, so the
# CEDRIC_* switches the check scripts use (DevHooks.swift) work. Never
# ship it: any local program could launch it with those switches and use
# Owlink's file-access grants. Scripts/release.sh passes --release, which
# leaves them out (Sources/CedricCore/DevEnvironment.swift); a release
# build honours only a few path-free ones its own launch check needs.
#
# --universal first tries one multi-arch `swift build`. SwiftPM 6.0 (the
# macOS 14 Command Line Tools) hands multi-arch builds to xcbuild, which
# ships only with Xcode; then the script builds each architecture on its
# own and joins them with lipo.
#
# Version: CEDRIC_VERSION (the release workflow sets it from the tag), else
# CedricVersion.source (Sources/CedricCore/Version.swift), the one place the
# version is written down. CFBundleVersion is the same string, as in
# Tankard, so About shows "Version 0.1.0" with no "(N)" after it.
#
# Name: the app is "Owlink" (bundle "Owlink.app"); the owl is
# Cedric. Everything a user's data hangs on keeps the owl's name: bundle id
# net.mindtricks.cedric (UserDefaults domain), the cedric:// scheme,
# ~/Library/Application Support/Cedric, and the executable Contents/MacOS/Cedric
# (crash reports and `pgrep -x Cedric`).
# The new bundle isn't force-registered: a dev build in dist shouldn't take
# over Open With from an installed copy; Launch Services registers it (with
# its new name) the first time it is opened.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=dist
SIGN=adhoc
ARCH_ARGS=()
UNIVERSAL=0
CHECKS=1
while [ $# -gt 0 ]; do
    case "$1" in
        --universal) UNIVERSAL=1 ;;
        --arch) ARCH_ARGS+=(--arch "$2"); shift ;;
        --out) OUT=$2; shift ;;
        --no-sign) SIGN=none ;;
        --release) CHECKS=0 ;;
        -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
        *) echo "bundle-app.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

SOURCE_VERSION=$(sed -n 's/.*static let source = "\([^"]*\)".*/\1/p' Sources/CedricCore/Version.swift)
[ -n "$SOURCE_VERSION" ] || { echo "bundle-app.sh: no CedricVersion.source in Sources/CedricCore/Version.swift" >&2; exit 1; }
VERSION=${CEDRIC_VERSION:-$SOURCE_VERSION}
BUILD=$VERSION

# The dev switches: compiled in for a check build only (see the top).
SWIFTC_FLAGS=()
[ $CHECKS = 1 ] && SWIFTC_FLAGS=(-Xswiftc -DCEDRIC_CHECKS)

LIPO_FROM=()
if [ $UNIVERSAL = 1 ]; then
    echo "==> swift build -c release --arch x86_64 --arch arm64"
    if swift build -c release ${SWIFTC_FLAGS[@]+"${SWIFTC_FLAGS[@]}"} --arch x86_64 --arch arm64 --product CedricApp; then
        BIN=$(swift build -c release ${SWIFTC_FLAGS[@]+"${SWIFTC_FLAGS[@]}"} --arch x86_64 --arch arm64 --show-bin-path)
    else
        echo "==> one multi-arch build isn't available here; building each architecture and joining them"
        for arch in x86_64 arm64; do
            swift build -c release ${SWIFTC_FLAGS[@]+"${SWIFTC_FLAGS[@]}"} --arch "$arch" --product CedricApp
            LIPO_FROM+=("$(swift build -c release ${SWIFTC_FLAGS[@]+"${SWIFTC_FLAGS[@]}"} --arch "$arch" --show-bin-path)/CedricApp")
        done
        BIN=$(swift build -c release ${SWIFTC_FLAGS[@]+"${SWIFTC_FLAGS[@]}"} --arch arm64 --show-bin-path)
    fi
else
    echo "==> swift build -c release ${SWIFTC_FLAGS[*]:-} ${ARCH_ARGS[*]:-}"
    swift build -c release ${SWIFTC_FLAGS[@]+"${SWIFTC_FLAGS[@]}"} ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --product CedricApp
    BIN=$(swift build -c release ${SWIFTC_FLAGS[@]+"${SWIFTC_FLAGS[@]}"} ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)
fi

APP="$OUT/Owlink.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The app icon (Finder, Dock, About). Made by tools/icon/cedric_icon.py, committed.
[ -f Resources/AppIcon.icns ] || { echo "bundle-app.sh: missing Resources/AppIcon.icns" >&2; exit 1; }
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Document icons, one per text file type (tools/icon/doc_icons.py, committed);
# Info.plist names them below, from Resources/document-types.txt.
# They sit next to AppIcon.icns, where Launch Services looks for them.
cp Resources/DocIcons/*.icns "$APP/Contents/Resources/"
# The assistant owl's poses and sprite strips (same generator).
mkdir -p "$APP/Contents/Resources/Owl"
cp Resources/Owl/*.png "$APP/Contents/Resources/Owl/"
if [ ${#LIPO_FROM[@]} -gt 0 ]; then
    lipo -create "${LIPO_FROM[@]}" -output "$APP/Contents/MacOS/Cedric"
else
    cp "$BIN/CedricApp" "$APP/Contents/MacOS/Cedric"
fi
# SwiftPM adds an @executable_path/../lib rpath that nothing uses (the
# bundle has no lib folder; llama.framework is found through ../Frameworks).
# Dropped, so the loader never searches there first.
# (Captured first: `grep -q` on a pipe would SIGPIPE otool under pipefail.)
load_cmds=$(otool -l "$APP/Contents/MacOS/Cedric")
if grep -q "path @executable_path/../lib " <<<"$load_cmds"; then
    install_name_tool -delete_rpath "@executable_path/../lib" "$APP/Contents/MacOS/Cedric"
fi
# llama.cpp for the built-in AI engine: the pinned XCFramework's macOS
# slice is already universal, so either architecture's copy will do. The
# executable finds it through its @executable_path/../Frameworks rpath.
# A multi-arch build through xcbuild (Xcode, as on CI) may not copy the
# framework next to the binary; then take it from the resolved XCFramework.
FW_SRC="$BIN/llama.framework"
if [ ! -d "$FW_SRC" ]; then
    FW_SRC=$(find .build/artifacts -maxdepth 6 -type d -path '*llama.xcframework/macos-*/llama.framework' 2>/dev/null | head -1)
fi
[ -n "$FW_SRC" ] && [ -d "$FW_SRC" ] || { echo "bundle-app.sh: missing llama.framework (not in $BIN or .build/artifacts)" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$FW_SRC" "$APP/Contents/Frameworks/llama.framework"
# The built-in engine's model list (downloads are pinned by URL + SHA-256).
mkdir -p "$APP/Contents/Resources/AI"
cp Resources/AI/models.json "$APP/Contents/Resources/AI/models.json"
cp Resources/AI/owl-tool-scores.json "$APP/Contents/Resources/AI/owl-tool-scores.json"
mkdir -p "$APP/Contents/Resources/AI/licenses"
cp Resources/AI/licenses/Apache-2.0.txt "$APP/Contents/Resources/AI/licenses/Apache-2.0.txt"
cp Resources/AI/licenses/Qwen-Research-License.txt "$APP/Contents/Resources/AI/licenses/Qwen-Research-License.txt"
# The command-line launcher ships inside the app; see Scripts/cedric.
cp Scripts/cedric "$APP/Contents/Resources/cedric"
chmod +x "$APP/Contents/Resources/cedric"

# The text file types (Resources/document-types.txt, which explains the
# ranks): one document type each with its icon, LSHandlerRank None (they
# never make Owlink a default; Settings › Default editor for… or Get Info
# does, when the user asks), the catch-all "Text" type at Alternate as in
# 0.2.x, and an imported declaration for the few types macOS lacks.
TEXT_TYPES=""
IMPORTED_TYPES=""
while IFS='|' read -r label icon name utis decl; do
    case "$label" in ''|'#'*) continue ;; esac
    [ -f "Resources/DocIcons/$icon.icns" ] || { echo "bundle-app.sh: missing Resources/DocIcons/$icon.icns" >&2; exit 1; }
    rank=None
    [ "$label" = "*" ] && rank=Alternate
    items=""
    IFS=',' read -ra U <<<"$utis"
    for u in "${U[@]}"; do items+="                <string>$u</string>
"; done
    TEXT_TYPES+="        <dict>
            <key>CFBundleTypeName</key>
            <string>$name</string>
            <key>CFBundleTypeIconFile</key>
            <string>$icon.icns</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>$rank</string>
            <key>LSItemContentTypes</key>
            <array>
$items            </array>
        </dict>
"
    if [ "$decl" != "-" ]; then
        conf=""; exts=""
        IFS=',' read -ra C <<<"${decl%%;*}"
        for c in "${C[@]}"; do conf+="<string>$c</string>"; done
        IFS=',' read -ra E <<<"${decl#*;}"
        for e in "${E[@]}"; do exts+="<string>$e</string>"; done
        IMPORTED_TYPES+="        <dict>
            <key>UTTypeIdentifier</key>
            <string>${U[0]}</string>
            <key>UTTypeDescription</key>
            <string>$name</string>
            <key>UTTypeConformsTo</key>
            <array>$conf</array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>$exts</array>
            </dict>
        </dict>
"
    fi
done < Resources/document-types.txt

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>net.mindtricks.cedric</string>
    <key>CFBundleName</key>
    <string>Owlink</string>
    <key>CFBundleDisplayName</key>
    <string>Owlink</string>
    <key>CFBundleExecutable</key>
    <string>Cedric</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>net.mindtricks.cedric.open</string>
            <key>CFBundleURLSchemes</key>
            <array><string>cedric</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <!-- PDFs open in a read-only viewer tab. Alternate: Preview stays the default. -->
            <key>CFBundleTypeName</key>
            <string>PDF Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
            </array>
        </dict>
        <dict>
            <!-- Images open in a read-only image tab. Alternate: Preview stays the default. SVG is text. -->
            <key>CFBundleTypeName</key>
            <string>Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.png</string>
                <string>public.jpeg</string>
                <string>com.compuserve.gif</string>
                <string>public.heic</string>
                <string>public.heif</string>
                <string>public.avif</string>
                <string>org.webmproject.webp</string>
                <string>public.tiff</string>
                <string>com.microsoft.bmp</string>
                <string>com.microsoft.ico</string>
                <string>com.apple.icns</string>
                <string>public.jpeg-2000</string>
                <string>com.adobe.photoshop-image</string>
                <string>com.truevision.tga-image</string>
            </array>
        </dict>
        <dict>
            <!-- Office and iWork documents open in a read-only Quick Look tab. Alternate. -->
            <key>CFBundleTypeName</key>
            <string>Office Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.openxmlformats.wordprocessingml.document</string>
                <string>org.openxmlformats.spreadsheetml.sheet</string>
                <string>org.openxmlformats.presentationml.presentation</string>
                <string>com.microsoft.word.doc</string>
                <string>com.microsoft.excel.xls</string>
                <string>com.microsoft.powerpoint.ppt</string>
                <string>com.apple.iwork.pages.sffpages</string>
                <string>com.apple.iwork.numbers.sffnumbers</string>
                <string>com.apple.iwork.keynote.sffkey</string>
                <string>com.apple.iwork.pages.pages</string>
                <string>com.apple.iwork.numbers.numbers</string>
                <string>com.apple.iwork.keynote.key</string>
                <string>com.apple.rtfd</string>
                <string>com.apple.flat-rtfd</string>
            </array>
        </dict>
$TEXT_TYPES    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
$IMPORTED_TYPES    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
SHORT=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
LONG=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
[ "$SHORT" = "$LONG" ] || { echo "bundle-app.sh: CFBundleVersion ($LONG) must equal CFBundleShortVersionString ($SHORT)" >&2; exit 1; }
printf 'APPL????' > "$APP/Contents/PkgInfo"
# The document types and icons as designed (quiet unless something is off).
Scripts/doctypes-check.sh "$APP" | grep -v ' PASS ' >&2 || true
Scripts/doctypes-check.sh "$APP" >/dev/null

if [ "$SIGN" = adhoc ]; then
    # Ad-hoc: no identity, no Gatekeeper approval. No App Sandbox: an
    # editor opens arbitrary files by path from the command line.
    codesign -s - --force --deep "$APP"
    codesign --verify --deep --strict "$APP"
fi

echo "==> $APP ($VERSION): $(lipo -archs "$APP/Contents/MacOS/Cedric"), signing: $SIGN, $([ $CHECKS = 1 ] && echo "CHECK build (dev switches on; don't ship)" || echo "release build (dev switches off)")"
