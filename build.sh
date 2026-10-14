#!/bin/zsh
# 사진지도.app 빌드 → ~/Applications/사진지도.app
set -e
cd "${0:A:h}"
# 배포용: APP=경로 ARCHS="arm64 x86_64" ./build.sh  (dist.sh가 이렇게 부른다)
APP=${APP:-~/Applications/사진지도.app}
ARCHS_SET=$ARCHS
ARCHS=(${=ARCHS:-arm64})
# 앱을 지웠다 다시 만들면 Dock에 고정한 아이콘이 '없는 앱(🚫)'으로 바뀌므로, 지우지 않고 안의 파일만 바꾼다
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BINS=()
for a in $ARCHS; do
  swiftc -module-name PhotoMap -parse-as-library -swift-version 5 -O -target $a-apple-macos14 PhotoMap.swift -o "/tmp/PhotoMap-$a"
  BINS+=("/tmp/PhotoMap-$a")
done
lipo -create $BINS -output "$APP/Contents/MacOS/PhotoMap"
rm -f $BINS
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$APP/Contents/Resources/"
# 한국어 앱이라고 알려야 기본 메뉴(파일·편집·보기·윈도우·도움말)가 한국어로 나온다
mkdir -p "$APP/Contents/Resources/ko.lproj"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>사진지도</string>
  <key>CFBundleDisplayName</key><string>사진지도</string>
  <key>CFBundleIdentifier</key><string>com.mungdara.photomap</string>
  <key>CFBundleExecutable</key><string>PhotoMap</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>CFBundleLocalizations</key><array><string>ko</string></array>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force -s - "$APP"
touch "$APP"
# 배포용 빌드는 Launch Services에 등록하지 않는다(설치된 앱 대신 열리지 않게)
[[ -z "$ARCHS_SET" ]] && /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "빌드 완료: $APP"
