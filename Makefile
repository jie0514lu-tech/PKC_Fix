ARCHS = arm64 arm64e
TARGET = iphone:clang

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PKC60sFix
PKC60sFix_FILES = src/PKC60sFix.xm
PKC60sFix_CFLAGS = -fobjc-arc -Wno-error
PKC60sFix_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
