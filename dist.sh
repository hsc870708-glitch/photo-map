#!/bin/zsh
# 배포용 zip 만들기 → dist/PhotoMap.zip (애플 실리콘 + 인텔 Mac 모두 실행)
# 압축을 풀면 '사진지도' 폴더 안에 앱과 설치 안내(처음_읽어주세요.txt)가 함께 나온다
set -e
cd "${0:A:h}"
rm -rf dist && mkdir -p dist/사진지도
APP="$PWD/dist/사진지도/사진지도.app" ARCHS="arm64 x86_64" ./build.sh
cp 처음_읽어주세요.txt dist/사진지도/
ditto -c -k --norsrc --noextattr --keepParent dist/사진지도 dist/PhotoMap.zip
rm -rf dist/사진지도
ls -lh dist
