# VCamServerStart — schwebender Button zum manuellen Start des LordVCAM-Fake-Servers
TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e
TWEAK_NAME := VCamServerStart

VCamServerStart_FILES := VCamServerStart.x
VCamServerStart_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamServerStart_FRAMEWORKS := UIKit
VCamServerStart_LIBRARIES := substrate

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
