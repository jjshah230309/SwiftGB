#!/bin/bash
# SwiftGB build script: builds with SwiftPM (no Xcode needed) and wraps the binary in an ad-hoc-signed .app

set -e

# Configuration
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build"
RELEASE_DIR="${BUILD_DIR}/release"
APP_NAME="SwiftGB"
BUNDLE_ID="com.swiftgb.SwiftGB"
VERSION="1.0.4"
BUILD_NUMBER="2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse arguments
BUILD_CONFIG="release"
SIGN_IDENTITY="-"
NOTARIZE=false
CREATE_DMG=false
RUN_TESTS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            BUILD_CONFIG="debug"
            shift
            ;;
        --sign)
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --notarize)
            NOTARIZE=true
            shift
            ;;
        --dmg)
            CREATE_DMG=true
            shift
            ;;
        --test)
            RUN_TESTS=true
            shift
            ;;
        --clean)
            log_info "Cleaning build directory..."
            rm -rf "${BUILD_DIR}"
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

log_info "Building SwiftGB (${BUILD_CONFIG})..."
log_info "Project directory: ${PROJECT_DIR}"

# Step 1: Build with Swift Package Manager
log_info "Running swift build..."
cd "${PROJECT_DIR}"

if [[ "${BUILD_CONFIG}" == "release" ]]; then
    swift build -c release --arch arm64
else
    swift build -c debug --arch arm64
fi

if [[ $? -ne 0 ]]; then
    log_error "Build failed!"
    exit 1
fi

log_success "Swift build completed"

# Step 2: Run tests if requested
if [[ "${RUN_TESTS}" == true ]]; then
    log_info "Running tests..."
    swift test --parallel
    if [[ $? -ne 0 ]]; then
        log_error "Tests failed!"
        exit 1
    fi
    log_success "All tests passed"
fi

# Step 3: Create app bundle
log_info "Creating app bundle..."

APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"

# Clean previous bundle
rm -rf "${APP_BUNDLE}"

# Create directory structure
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"
mkdir -p "${FRAMEWORKS_DIR}"

# Copy executable
EXECUTABLE="${RELEASE_DIR}/${APP_NAME}"
if [[ ! -f "${EXECUTABLE}" ]]; then
    # Try debug build
    EXECUTABLE="${BUILD_DIR}/debug/${APP_NAME}"
fi

if [[ ! -f "${EXECUTABLE}" ]]; then
    log_error "Executable not found at ${EXECUTABLE}"
    exit 1
fi

cp "${EXECUTABLE}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# (Metal shaders are compiled at runtime from source strings; nothing to copy.)

# Copy any additional resources
if [[ -d "${PROJECT_DIR}/Resources" ]]; then
    cp -R "${PROJECT_DIR}/Resources/"* "${RESOURCES_DIR}/" 2>/dev/null || true
fi

# Create Info.plist
log_info "Creating Info.plist..."
cat > "${CONTENTS_DIR}/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.games</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>SwiftGB uses the local network to link two consoles for multiplayer, like a link cable.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_swiftgb-link._tcp</string>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSAppSleepDisabled</key>
    <true/>
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Game Boy Advance ROM</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.nintendo.game-boy-advance-rom</string>
                <string>public.data</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Game Boy ROM</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.nintendo.game-boy-rom</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Game Boy Color ROM</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.nintendo.game-boy-color-rom</string>
            </array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.nintendo.game-boy-advance-rom</string>
            <key>UTTypeDescription</key>
            <string>Game Boy Advance ROM</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>gba</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.nintendo.game-boy-rom</string>
            <key>UTTypeDescription</key>
            <string>Game Boy ROM</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>gb</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.nintendo.game-boy-color-rom</string>
            <key>UTTypeDescription</key>
            <string>Game Boy Color ROM</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>gbc</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

# Create app icon if not exists
if [[ ! -f "${RESOURCES_DIR}/AppIcon.icns" ]]; then
    log_warning "AppIcon.icns not found, creating placeholder..."
    # Create a simple icon using sips if possible
    # For now, we'll skip this
fi

# Sign the app
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    log_info "Signing app with identity: ${SIGN_IDENTITY}"
    codesign --force --deep --sign "${SIGN_IDENTITY}" \
        --options runtime \
        --entitlements "${PROJECT_DIR}/Scripts/entitlements.plist" \
        "${APP_BUNDLE}" 2>/dev/null || {
        log_warning "Failed to sign with custom identity, using ad-hoc signing"
        codesign --force --deep --sign - "${APP_BUNDLE}"
    }
else
    log_info "Ad-hoc signing..."
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

# Verify signature
codesign --verify --deep --strict "${APP_BUNDLE}"

log_success "App bundle created at: ${APP_BUNDLE}"

# Step 4: Notarize if requested
if [[ "${NOTARIZE}" == true ]]; then
    log_info "Notarizing app..."

    # Create zip for notarization
    ZIP_PATH="${BUILD_DIR}/${APP_NAME}.zip"
    ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

    # Submit for notarization
    xcrun notarytool submit "${ZIP_PATH}" \
        --apple-id "${APPLE_ID}" \
        --team-id "${TEAM_ID}" \
        --password "${APP_PASSWORD}" \
        --wait

    if [[ $? -eq 0 ]]; then
        # Staple the notarization
        xcrun stapler staple "${APP_BUNDLE}"
        log_success "App notarized and stapled"
    else
        log_error "Notarization failed"
        exit 1
    fi
fi

# Step 5: Create DMG if requested
if [[ "${CREATE_DMG}" == true ]]; then
    log_info "Creating DMG..."

    DMG_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"
    TEMP_DMG="${BUILD_DIR}/temp.dmg"

    # Create a temporary DMG
    hdiutil create -srcfolder "${APP_BUNDLE}" \
        -volname "${APP_NAME}" \
        -fs HFS+ \
        -fsargs "-c c=64,a=16,e=16" \
        -format UDRW \
        -size 100m \
        "${TEMP_DMG}"

    # Convert to compressed DMG
    hdiutil convert "${TEMP_DMG}" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "${DMG_PATH}"

    rm -f "${TEMP_DMG}"

    log_success "DMG created at: ${DMG_PATH}"
fi

# Summary
echo ""
log_success "Build completed successfully!"
echo ""
echo "App bundle: ${APP_BUNDLE}"
echo ""
echo "To run the app:"
echo "  open \"${APP_BUNDLE}\""
echo ""
echo "Or from command line:"
echo "  \"${MACOS_DIR}/${APP_NAME}\""