#!/bin/zsh
# 배포용 zip 만들기 → dist/사진지도.zip (애플 실리콘 + 인텔 Mac 모두 실행)
set -e
cd "${0:A:h}"
rm -rf dist && mkdir -p dist
APP="$PWD/dist/사진지도.app" ARCHS="arm64 x86_64" ./build.sh
cp README.md dist/ 2>/dev/null || true
ditto -c -k --norsrc --noextattr --keepParent dist/사진지도.app dist/사진지도.zip
rm -rf dist/사진지도.app
ls -lh dist
