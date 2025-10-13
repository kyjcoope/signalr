#include "glue.h"

JNIEXPORT jobject JNICALL
Java_com_jci_mediaprocessor_media_1processor_BaseRenderer_getBufferDirect(
    JNIEnv* env, jclass clazz, jlong ptr, jint size) {
  if (ptr == 0 || size <= 0) return NULL;
  // No copy: Java will read directly from native memory. Ensure the lifetime is valid
  // until the GL upload completes on the Java side.
  return (*env)->NewDirectByteBuffer(env, (void*) (intptr_t) ptr, (jlong) size);
}

JNIEXPORT jlong JNICALL
Java_com_jci_mediaprocessor_media_1processor_MediaProcessorPlugin_getANativeWindow(
    JNIEnv* env, jclass clazz, jobject surface) {
  if (surface == NULL) return 0;
  // Keep behavior you had before: pass a global ref back to Java as a jlong.
  jobject globalRef = (*env)->NewGlobalRef(env, surface);
  return (jlong) globalRef;
}

JNIEXPORT void JNICALL
Java_com_jci_mediaprocessor_media_1processor_MediaProcessorPlugin_releaseNativeWindow(
    JNIEnv* env, jclass clazz, jlong global_surface_ref) {
  if (global_surface_ref != 0) {
    (*env)->DeleteGlobalRef(env, (jobject) global_surface_ref);
  }
}
