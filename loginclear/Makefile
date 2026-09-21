# VCLoginClear — schwebender Button in SpringBoard zum Löschen des LordVCAM-Login-Keychain-Eintrags
TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e
TWEAK_NAME := VCLoginClear

VCLoginClear_FILES := VCLoginClear.x
VCLoginClear_CFLAGS := -fobjc-arc -Wno-unused-variable
VCLoginClear_FRAMEWORKS := UIKit Security
VCLoginClear_LIBRARIES := substrate

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
