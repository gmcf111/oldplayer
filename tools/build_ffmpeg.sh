#!/usr/bin/env bash
# Builds a lean, decode-only FFmpeg (static libs) for 32-bit armv7 / iOS 6+.
#
# Runs in GitHub Actions on ubuntu-latest, reusing the Theos iOS toolchain
# (clang) and the iPhoneOS9.3.sdk that build.yml already fetches. The result
# is installed to $FFMPEG_PREFIX (default: $GITHUB_WORKSPACE/ThirdParty/ffmpeg-armv7)
# and picked up by the Makefile, which defines HAS_FFMPEG=1 when the prefix exists.
#
# Only decoders/demuxers OldPlayer needs are enabled (no encoders, muxers,
# filters, devices, programs, TLS, or hardware accel) to keep the binary small
# enough for old devices. ARM asm (NEON) stays on via gas-preprocessor.
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-6.1.2}"
PREFIX="${FFMPEG_PREFIX:-${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}/ThirdParty/ffmpeg-armv7}"

if [ -f "$PREFIX/lib/libavformat.a" ] && [ -f "$PREFIX/include/libavformat/avformat.h" ]; then
  echo "FFmpeg already built at $PREFIX - skipping"
  exit 0
fi

THEOS="${THEOS:?THEOS must be set (theos checkout path)}"
TOOLCHAIN="$THEOS/toolchain/linux/iphone/bin"
CLANG="$TOOLCHAIN/clang"
SDK="$THEOS/sdks/iPhoneOS9.3.sdk"
[ -x "$CLANG" ] || { echo "::error::Theos clang missing at $CLANG"; ls "$TOOLCHAIN" || true; exit 1; }
[ -d "$SDK" ] || { echo "::error::iPhoneOS9.3.sdk missing at $SDK"; exit 1; }

WORK="${WORKDIR:-/tmp/ffmpeg-build}"
mkdir -p "$WORK" "$PREFIX"
cd "$WORK"

echo "=== Fetching FFmpeg $FFMPEG_VERSION ==="
TARBALL="ffmpeg-$FFMPEG_VERSION.tar.xz"
if [ ! -f "$TARBALL" ]; then
  curl -LfsS --retry 3 --retry-delay 5 -o "$TARBALL" \
    "https://ffmpeg.org/releases/$TARBALL" || \
  curl -LfsS --retry 3 --retry-delay 5 -o "$TARBALL" \
    "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n$FFMPEG_VERSION.tar.gz" || {
    echo "::error::Failed to download FFmpeg $FFMPEG_VERSION"; exit 1
  }
fi
file "$TARBALL"
rm -rf "ffmpeg-$FFMPEG_VERSION" "FFmpeg-n$FFMPEG_VERSION"
if file "$TARBALL" | grep -q XZ; then
  tar -xJf "$TARBALL"
else
  tar -xzf "$TARBALL"
fi
if [ -d "ffmpeg-$FFMPEG_VERSION" ]; then SRC="$WORK/ffmpeg-$FFMPEG_VERSION";
else SRC="$WORK/FFmpeg-n$FFMPEG_VERSION"; fi
[ -f "$SRC/configure" ] || { echo "::error::FFmpeg source not unpacked"; ls "$WORK"; exit 1; }

echo "=== Fetching gas-preprocessor (ARM asm for clang) ==="
mkdir -p "$WORK/bin"
if [ ! -x "$WORK/bin/gas-preprocessor.pl" ]; then
  curl -LfsS --retry 3 --retry-delay 5 -o "$WORK/bin/gas-preprocessor.pl" \
    "https://raw.githubusercontent.com/libav/gas-preprocessor/master/gas-preprocessor.pl" || {
    echo "::error::Failed to download gas-preprocessor.pl"; exit 1
  }
  chmod +x "$WORK/bin/gas-preprocessor.pl"
fi
export PATH="$WORK/bin:$PATH"

echo "=== Linker detection (must be the toolchain's ld64, not GNU ld) ==="
LD_TOOL=""
for cand in "$TOOLCHAIN/ld" "$(command -v ld64 || true)"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then LD_TOOL="$cand"; break; fi
done
echo "ld64 candidate: ${LD_TOOL:-<none>}"
ls "$TOOLCHAIN" | head -30

echo "=== Compiler wrappers ==="
# Mirrors what Theos passes for TARGET=iphone:clang:9.3:6.0 plus an explicit
# -B/-fuse-ld so the driver links Mach-O with the toolchain's ld64.
cat > "$WORK/cc-flags.env" <<EOF
CLANG="$CLANG"
SDK="$SDK"
TOOLCHAIN="$TOOLCHAIN"
LD_TOOL="$LD_TOOL"
EOF
cat > "$WORK/cc-armv7" <<'EOF'
#!/bin/sh
HERE=$(dirname "$0")
. "$HERE/cc-flags.env"
EXTRA=""
if [ -n "$LD_TOOL" ]; then
  EXTRA="-B$TOOLCHAIN -fuse-ld=$LD_TOOL"
fi
# shellcheck disable=SC2086
exec "$CLANG" -arch armv7 -isysroot "$SDK" -miphoneos-version-min=6.0 $EXTRA "$@"
EOF
cat > "$WORK/as-armv7" <<'EOF'
#!/bin/sh
HERE=$(dirname "$0")
. "$HERE/cc-flags.env"
exec "$HERE/bin/gas-preprocessor.pl" -arch arm -- "$CLANG" -arch armv7 -isysroot "$SDK" -miphoneos-version-min=6.0 "$@"
EOF
chmod +x "$WORK/cc-armv7" "$WORK/as-armv7"
"$WORK/cc-armv7" --version | head -2

echo "=== Probing wrapper (compile + link a hello world) ==="
echo 'int main(void) { return 0; }' > "$WORK/probe.c"
if "$WORK/cc-armv7" "$WORK/probe.c" -o "$WORK/probe" 2>"$WORK/probe.err"; then
  echo "wrapper links OK"
  file "$WORK/probe" || true
else
  echo "::error::compiler wrapper cannot link; see probe output below"
  cat "$WORK/probe.err"
  exit 1
fi

pick_tool() {
  for cand in "$TOOLCHAIN/llvm-$1" "$TOOLCHAIN/$1" "$(command -v "llvm-$1" || true)" "$(command -v "$1" || true)"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then echo "$cand"; return 0; fi
  done
  echo "$1"
}
AR_TOOL=$(pick_tool ar); RANLIB_TOOL=$(pick_tool ranlib); NM_TOOL=$(pick_tool nm)
echo "ar=$AR_TOOL ranlib=$RANLIB_TOOL nm=$NM_TOOL"

DEMUXERS="mov,m4v,avi,flv,rm,asf,mpegts,mpegps,mpegvideo,matroska,ogg,mp3,flac,ape,wv,tta,mpc,mpc8,aac,ac3,dts,wav,aiff,dv,h264"
DECODERS="h264,hevc,mpeg4,mpeg2video,mpeg1video,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmv1,wmv2,wmv3,vc1,rv10,rv20,rv30,rv40,vp6,vp6a,vp6f,vp8,vp9,theora,flv,svq1,svq3,h263,h263i,mjpeg,mjpegb,png,bmp,gif,aac,ac3,eac3,dca,mp3,mp2,mp1,wmav1,wmav2,wmavoice,wmalossless,vorbis,opus,speex,flac,alac,ape,wavpack,tta,mpc7,mpc8,shorten,cook,sipr,atrac3,ralf,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_u8,pcm_alaw,pcm_mulaw,pcm_f32le,adpcm_ms,adpcm_ima_wav,dvvideo"
PARSERS="h264,hevc,mpeg4video,mpegvideo,mpegaudio,aac,ac3,dca,vc1,rv30,rv40,h263,mjpeg,vp3,vp8,opus,vorbis,flac,ape,png,bmp,dvvideo"

echo "=== Configuring FFmpeg (decode-only, armv7, iOS 6+) ==="
cd "$SRC"
./configure \
  --prefix="$PREFIX" \
  --target-os=darwin --arch=arm --cpu=cortex-a8 \
  --enable-cross-compile \
  --cc="$WORK/cc-armv7" \
  --as="$WORK/as-armv7" \
  --ar="$AR_TOOL" --ranlib="$RANLIB_TOOL" --nm="$NM_TOOL" \
  --sysroot="$SDK" \
  --extra-cflags="-O2" \
  --disable-everything \
  --disable-programs --disable-doc \
  --disable-avdevice --disable-avfilter --disable-postproc \
  --disable-encoders --disable-muxers \
  --disable-videotoolbox --disable-audiotoolbox --disable-securetransport \
  --disable-bzlib --disable-lzma \
  --enable-zlib --enable-iconv \
  --enable-small --disable-debug \
  --enable-demuxer="$DEMUXERS" \
  --enable-decoder="$DECODERS" \
  --enable-parser="$PARSERS" \
  --enable-bsf=mpeg4_unpack_bframes \
  --enable-protocol=file,http,tcp || {
  echo "::error::FFmpeg configure failed; last 60 lines of config.log:"
  tail -60 ffbuild/config.log || tail -60 config.log || true
  exit 1
}

if grep -q "#define HAVE_NEON 1" config.h; then
  echo "NEON enabled"
else
  echo "::warning::NEON not enabled in FFmpeg build (soft decode will be slower)"
fi

echo "=== Building ==="
make -j"$(nproc)"
make install

echo "=== Verifying ==="
ls -lh "$PREFIX/lib/"*.a
file "$PREFIX/lib/libavcodec.a" | head -2
"$NM_TOOL" "$PREFIX/lib/libavcodec.a" 2>/dev/null | head -3 || true
echo "FFmpeg $FFMPEG_VERSION for armv7 installed to $PREFIX"
