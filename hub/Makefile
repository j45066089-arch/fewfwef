# VCamHub — WS-Server + Floating-Status-Button in SpringBoard
# Eigenständiges Paket, weil VCamInject separat gebaut wird.
TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e
TWEAK_NAME := VCamHub

VCamHub_FILES := Hub.x
VCamHub_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamHub_FRAMEWORKS := UIKit
VCamHub_LIBRARIES := substrate

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
