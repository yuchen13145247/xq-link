#!/usr/bin/env bash
# 在 Linux 上用 clang + theos 的 iOS SDK + ld64.lld 交叉编译出 iOS App 并打包 IPA
set -euo pipefail

SDK="${SDK:-/tmp/sdks/iPhoneOS16.5.sdk}"
PK="${PK:-/tmp/pikafish}"
NNUE="${NNUE:-/tmp/pikafish.nnue}"
OUT="build"

rm -rf "$OUT"
mkdir -p "$OUT/obj"

BASE=(-target arm64-apple-ios15.0 -isysroot "$SDK" -O2 -I"$PK/src" -DNNUE_EMBEDDING_OFF)
OBJC=("${BASE[@]}" -fobjc-arc)
CPP=("${BASE[@]}" -std=c++17)

echo "==> 1/4 编译 Pikafish 引擎"
for f in "$PK"/src/*.cpp "$PK"/src/nnue/*.cpp; do
  case "$f" in */main.cpp) echo "   skip $f"; continue ;; esac
  clang++ "${CPP[@]}" -c "$f" -o "$OUT/obj/$(basename "${f%.cpp}").o"
done
clang++ "${CPP[@]}" -c XiangqiLink/Engine/engine_shim.cpp -o "$OUT/obj/engine_shim.o"

echo "==> 2/4 编译 App"
clang   "${OBJC[@]}" -c XiangqiLink/main.m           -o "$OUT/obj/main.o"
clang   "${OBJC[@]}" -c XiangqiLink/ViewController.m -o "$OUT/obj/ViewController.o"
clang   "${OBJC[@]}" -c XiangqiLink/TouchInjector.m  -o "$OUT/obj/TouchInjector.o"
clang++ "${CPP[@]}"  -fobjc-arc -c XiangqiLink/EngineBridge.mm -o "$OUT/obj/EngineBridge.o"

echo "==> 3/4 链接"
ld64.lld -arch arm64 -platform_version ios 15.0 15.0 -syslibroot "$SDK" \
  -o "$OUT/XiangqiLink" "$OUT"/obj/*.o \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -lobjc -lc++ -lSystem

echo "==> 4/4 组装 .app"
APP="$OUT/Payload/XiangqiLink.app"
mkdir -p "$APP"
cp "$OUT/XiangqiLink" "$APP/XiangqiLink"
cp XiangqiLink/Info.plist "$APP/Info.plist"
if [ -f "$NNUE" ]; then
  cp "$NNUE" "$APP/pikafish.nnue"
else
  echo "!! 没有 nnue，引擎会在启动时报错"
fi

( cd "$OUT" && zip -qry XiangqiLink.ipa Payload )
ls -lh "$OUT/XiangqiLink.ipa"
