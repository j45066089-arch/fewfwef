# VCamUSB — virtuelle Kamera (Dopamine2-roothide / Relaxin)
#   VCamHub   -> SpringBoard (WS-Server + Floating-Button via UIWindow)
#   VCamInject-> mediaserverd (WS-Client + Decode + FigCapture-Frame-Swap)
#   VCamProbe -> minimaler Lade-/Diagnose-Canary (beide Prozesse)
#
# Build:  make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
# WICHTIG: 14.0-Deployment nötig, damit die Toolchain arm64e bauen kann!
# (iOS 13.0 + arm64e geht nicht — Warning im CI-Log. Das Gerät ist arm64e,
#  roothide lädt nur Universal-Binaries sauber.)
TARGET := iphone:clang:latest:14.0
# Explizit BEIDE Archs bauen — das Gerät ist arm64e (A11), roothide lädt
# nur Universal-Binaries sauber. Ohne ARCHS baut Theos nur arm64.
ARCHS := arm64 arm64e
TWEAK_NAME := VCamInject

# ---- Inject: Substrate (%hook) + Video-Decoder + Photo support
VCamInject_FILES := Inject.x
VCamInject_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamInject_LDFLAGS := -Wl,-u,_VCamInject_start -Wl,-exported_symbol,_VCamInject_start
VCamInject_FRAMEWORKS := CydiaSubstrate CoreVideo CoreMedia VideoToolbox Accelerate IOSurface
VCamInject_LIBRARIES := notify

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
