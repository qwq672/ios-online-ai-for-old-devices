# Minimal iOS 7 UI rendering test — no custom styling, pure system controls.
THEOS_PROJECT_DIR = .
TARGET := iphone:clang:7.1:7.0
ARCHS = armv7 armv7s
INSTALL_PATH = /Applications
APP_NAME = iOS7Test
iOS7Test_FILES = main.m AppDelegate.m ViewController.m
iOS7Test_FRAMEWORKS = UIKit Foundation CoreGraphics
iOS7Test_CFLAGS = -fno-objc-arc -fobjc-legacy-dispatch -fno-objc-exceptions
iOS7Test_LDFLAGS = -ios_version_min 7.0

export THEOS_PROJECT_DIR

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/application.mk
