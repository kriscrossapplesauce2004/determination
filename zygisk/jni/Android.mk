LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE     := determination
LOCAL_SRC_FILES  := main.cpp
LOCAL_C_INCLUDES := $(LOCAL_PATH)/../../control/include
LOCAL_LDLIBS     := -llog
LOCAL_CFLAGS     := -Wall -Wextra -std=c++17
include $(BUILD_SHARED_LIBRARY)
