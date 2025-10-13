// media_processor_jni.cpp
#include <jni.h>
#include <android/native_window_jni.h> // ANativeWindow_fromSurface, _release

extern "C" JNIEXPORT jlong JNICALL
Java_com_jci_mediaprocessor_media_1processor_MediaProcessorPlugin_nativeAcquireNativeWindow(
    JNIEnv* env, jclass /*clazz*/, jobject surface) {
  ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
  // window may be NULL if the Surface is invalid; handle that in Java if needed.
  return reinterpret_cast<jlong>(window);
}

extern "C" JNIEXPORT void JNICALL
Java_com_jci_mediaprocessor_media_1processor_MediaProcessorPlugin_nativeReleaseNativeWindow(
    JNIEnv* /*env*/, jclass /*clazz*/, jlong ptr) {
  ANativeWindow* window = reinterpret_cast<ANativeWindow*>(ptr);
  if (window) {
    ANativeWindow_release(window);
  }
}