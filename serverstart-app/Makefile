# VCamServerStart — Homescreen-App-Icon: ein Tipp startet den LordVCAM-Fake-Server
TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

APPLICATION_NAME := VCamServerStart

VCamServerStart_FILES := main.m
VCamServerStart_FRAMEWORKS := UIKit
VCamServerStart_CFLAGS := -fobjc-arc -Wno-unused-variable
VCamServerStart_INSTALL_PATH := /Applications

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/application.mk
