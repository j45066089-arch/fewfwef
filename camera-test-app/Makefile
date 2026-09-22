TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

APPLICATION_NAME := CameraTest

CameraTest_FILES := main.m
CameraTest_FRAMEWORKS := UIKit AVFoundation CoreMedia
CameraTest_CFLAGS := -fobjc-arc -Wno-unused-variable
CameraTest_INSTALL_PATH := /Applications

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/application.mk
