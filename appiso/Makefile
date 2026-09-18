# AppIso — separates Mini-Tweak: ISO-Hook NUR in App-Prozessen (Diagnose + Fix)
TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e
TWEAK_NAME := AppIso

AppIso_FILES := AppIso.x
AppIso_CFLAGS := -fobjc-arc -Wno-unused-variable
AppIso_FRAMEWORKS := CydiaSubstrate Foundation UIKit
# notify liegt in libsystem (kein explizites Linken nötig)

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
