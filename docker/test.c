#include "glue.h"

JNIEXPORT jbyteArray JNICALL
Java_com_jci_mediaprocessor_media_1processor_BaseRenderer_getBuffer(
    JNIEnv* env, jclass clazz, jlong ptr, jint size) {
  jbyteArray bytes = (*env)->NewByteArray(env, size);
  if (bytes == NULL) return NULL;
  (*env)->SetByteArrayRegion(env, bytes, 0, size, (jbyte*)ptr);
  return bytes;
}

JNIEXPORT jlong JNICALL
Java_com_jci_mediaprocessor_media_1processor_MediaProcessorPlugin_getANativeWindow(
    JNIEnv* env, jclass clazz, jobject surface) {
  // Keep behavior you already had: store a global ref to the Surface jobject.
  jobject globalRef = (*env)->NewGlobalRef(env, surface);
  return (jlong)globalRef;
}

JNIEXPORT void JNICALL
Java_com_jci_mediaprocessor_media_1processor_MediaProcessorPlugin_releaseNativeWindow(
    JNIEnv* env, jclass clazz, jlong globalSurfaceRef) {
  if (globalSurfaceRef != 0) {
    (*env)->DeleteGlobalRef(env, (jobject)globalSurfaceRef);
  }
}
