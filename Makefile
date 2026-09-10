export ARCHS = armv7
export TARGET = iphone:clang:9.3:6.0
export TARGET_IPHONEOS_DEPLOYMENT_VERSION = 6.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = OldPlayer

# All ObjC sources - explicit list for determinism (Theos wildcards are fragile on Linux)
OldPlayer_FILES = \
	Sources/main.m \
	Sources/AppDelegate.m \
	Sources/Controllers/OPServerListViewController.m \
	Sources/Controllers/OPServerEditViewController.m \
	Sources/Controllers/OPFileBrowserViewController.m \
	Sources/Controllers/OPTransferViewController.m \
	Sources/Models/OPServer.m \
	Sources/Models/OPServerStore.m \
	Sources/Models/OPFileItem.m \
	Sources/Services/OPFileSourceFactory.m \
	Sources/Services/OPHTTPTask.m \
	Sources/Services/OPWebDAVClient.m \
	Sources/Services/OPWebDAVParser.m \
	Sources/Services/OPSocket.m \
	Sources/Services/OPFTPConnection.m \
	Sources/Services/OPFTPClient.m \
	Sources/Services/OPNTLM.m \
	Sources/Services/OPSMBSession.m \
	Sources/Services/OPSMBClient.m \
	Sources/Services/OPFTPSeekStream.m \
	Sources/Services/OPSMBSeekStream.m \
	Sources/Services/OPLocalHTTPProxy.m \
	Sources/Services/OPMediaCache.m \
	Sources/SoftDecode/OPSoftDecoder.m \
	Sources/SoftDecode/OPSoftVideoView.m \
	Sources/SoftDecode/OPSoftPlayerViewController.m

OldPlayer_FRAMEWORKS = UIKit Foundation MediaPlayer AVFoundation CoreGraphics QuartzCore CoreMedia AudioToolbox CFNetwork OpenGLES
OldPlayer_PRIVATE_FRAMEWORKS =

# iOS 6 compatibility: no NSURLSession, use NSURLConnection; frame layout, not AutoLayout-dependent
OldPlayer_CFLAGS = -fobjc-arc -fblocks -mios-version-min=6.0 -Wno-deprecated-declarations -Wno-unknown-pragmas -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter -O2 -ISources -ISources/Models -ISources/Services -ISources/Controllers -ISources/SoftDecode -ISources/Views -I.
OldPlayer_LDFLAGS = -Wl,-segalign,4000

# Soft decoding (FFmpeg, decode-only static libs built at CI time by
# tools/build_ffmpeg.sh). The workflow passes FFMPEG_PREFIX on the make
# command line; without it the SoftDecode sources compile to stubs and the
# app falls back to system playback.
# NOTE: this block must stay AFTER the base = assignments above, which would
# otherwise overwrite the += additions.
ifdef FFMPEG_PREFIX
OldPlayer_CFLAGS += -DHAS_FFMPEG=1 -I$(FFMPEG_PREFIX)/include
OldPlayer_LDFLAGS += -L$(FFMPEG_PREFIX)/lib -lavformat -lavcodec -lswscale -lswresample -lavutil -lz -liconv
endif

# No entitlements: this is a regular GUI app. Theos signs with a plain
# `ldid -S` pseudo-signature, which sideload tools (爱思助手/AltStore/
# Sideloadly) replace wholesale when re-signing. Embedded jailbreak
# entitlements (platform-application, no-container) are not grantable by
# personal certificates and make re-signed installs fail as "damaged".

include $(THEOS_MAKE_PATH)/application.mk

# IPA assembly lives in .github/workflows/build.yml ("Assemble IPA" step),
# which verifies the binary is a real Mach-O before packaging.
after-clean::
	rm -rf Payload *.ipa .theos packages
