TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = vcinject

vcinject_FILES = main.m dyld.m shellcode_inject.m rop_inject.m thread_utils.m task_utils.m arm64.m
vcinject_CFLAGS = -fobjc-arc -DTHEOS_LEAN_AND_MEAN
vcinject_CODESIGN_FLAGS = -Sentitlements.plist
vcinject_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
