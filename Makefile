TARGET := iphone:clang:latest:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Twitch

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Dvnloader

Dvnloader_FILES = Tweak.x $(wildcard Sources/*.m)
Dvnloader_CFLAGS = -fobjc-arc -ISources -Wno-deprecated-declarations -Wno-unused-variable -Wno-error
Dvnloader_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia AudioToolbox Photos
# "internal" = plain ObjC runtime hooks, no Substrate/ElleKit needed → works when injected into a sideloaded IPA.
Dvnloader_LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS_MAKE_PATH)/tweak.mk
