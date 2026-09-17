TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e
TWEAK_NAME := VCamProbe

VCamProbe_FILES := Probe.x
VCamProbe_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamProbe_FRAMEWORKS := Foundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk