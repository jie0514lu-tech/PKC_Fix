ARCHS = arm64 arm64e
TARGET = iphone:clang:16.0:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PKC60sFix
PKC60sFix_FILES = src/PKC60sFix.xm
PKC60sFix_CFLAGS = -fobjc-arc
PKC60sFix_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
