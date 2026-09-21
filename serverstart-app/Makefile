# VCamServerStart — Homescreen-App: Server starten + Login löschen (Keychain)
TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

APPLICATION_NAME := VCamServerStart

VCamServerStart_FILES := main.m
VCamServerStart_FRAMEWORKS := UIKit Security
VCamServerStart_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamServerStart_INSTALL_PATH := /Applications
VCamServerStart_CODESIGN_FLAGS := -SVCamServerStart.entitlements

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/application.mk
