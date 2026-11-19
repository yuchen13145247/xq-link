#!/usr/bin/env bash
# �?Linux 上用 clang + theos �?iOS SDK + ld64.lld 交叉编译�?iOS App（含 ReplayKit 扩展）并打包 IPA
set -euo pipefail

SDK="${SDK:-/tmp/sdks/iPhoneOS16.5.sdk}"
PK="${PK:-/tmp/pikafish}"
NNUE="${NNUE:-/tmp/pikafish.nnue}"
OUT="build"

rm -rf "$OUT"
mkdir -p "$OUT/obj" "$OUT/extobj"

BASE=(-target arm64-apple-ios15.0 -isysroot "$SDK" -O3 -DNDEBUG -DIS_64BIT -I"$PK/src" -IXiangqiLink -DNNUE_EMBEDDING_OFF)
OBJC=("${BASE[@]}" -fobjc-arc)
CPP=("${BASE[@]}" -std=c++17)
FRAMEWORKS=(-framework UIKit -framework Foundation -framework CoreGraphics -framework CoreText
            -framework CoreMedia -framework CoreVideo -framework Accelerate
            -framework ReplayKit -framework AVFoundation -framework AVKit -framework UserNotifications)
OBJNAME() { echo "$1" | sed "s|^$PK/src/||" | tr '/' '_' | sed 's/\.cpp$//'; }

echo "==> 1/5 编译 Pikafish 引擎"
ENGINE_SRCS=$(ls "$PK"/src/*.cpp "$PK"/src/nnue/*.cpp \
                 "$PK"/src/nnue/features/*.cpp \
                 "$PK"/src/external/common/*.cpp \
                 "$PK"/src/external/decompress/*.cpp 2>/dev/null)
for f in $ENGINE_SRCS; do
  case "$f" in */main.cpp) continue ;; esac
  clang++ "${CPP[@]}" -c "$f" -o "$OUT/obj/$(OBJNAME "$f").o"
done
clang++ "${CPP[@]}" -c XiangqiLink/Engine/engine_shim.cpp -o "$OUT/obj/engine_shim.o"

echo "==> 2/5 编译�?App"
for f in main ViewController TouchInjector Shared Recognizer Tracker; do
  clang "${OBJC[@]}" -c "XiangqiLink/$f.m" -o "$OUT/obj/app_$f.o"
done
clang++ "${CPP[@]}" -fobjc-arc -c XiangqiLink/EngineBridge.mm -o "$OUT/obj/EngineBridge.o"

echo "==> 3/5 编译广播扩展"
clang "${OBJC[@]}" -c XiangqiLink/BroadcastExt/SampleHandler.m -o "$OUT/extobj/SampleHandler.o"
clang "${OBJC[@]}" -c XiangqiLink/Shared.m -o "$OUT/extobj/Shared.o"

echo "==> 4/5 链接"
ld64.lld -arch arm64 -platform_version ios 15.0 15.0 -syslibroot "$SDK" \
  -o "$OUT/XiangqiLink" "$OUT"/obj/*.o \
  "${FRAMEWORKS[@]}" -lobjc -lc++ -lSystem

ld64.lld -arch arm64 -platform_version ios 15.0 15.0 -syslibroot "$SDK" \
  -e _NSExtensionMain -o "$OUT/BroadcastExt" "$OUT"/extobj/*.o \
  -framework ReplayKit -framework Foundation -framework UIKit \
  -framework Accelerate -framework CoreMedia -framework CoreVideo -framework CoreGraphics \
  -lobjc -lc++ -lSystem

echo "==> 5/5 组装 .app"
APP="$OUT/Payload/XiangqiLink.app"
mkdir -p "$APP/PlugIns/BroadcastExt.appex"
cp "$OUT/XiangqiLink" "$APP/XiangqiLink"
cp XiangqiLink/Info.plist "$APP/Info.plist"
cp "$OUT/BroadcastExt" "$APP/PlugIns/BroadcastExt.appex/BroadcastExt"
cp XiangqiLink/BroadcastExt/Info.plist "$APP/PlugIns/BroadcastExt.appex/Info.plist"
[ -f "$NNUE" ] && cp "$NNUE" "$APP/pikafish.nnue"

( cd "$OUT" && zip -qry XiangqiLink.ipa Payload )
ls -lh "$OUT/XiangqiLink.ipa"
echo "--- bundle ---"
find "$APP" -maxdepth 3 | sed "s|$OUT/||"
