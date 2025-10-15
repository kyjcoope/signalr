#include "glue.h"
#include <stdint.h>

JNIEXPORT jbyteArray JNICALL
Java_com_jci_mediaprocessor_media_1processor_BaseRenderer_getBuffer
  (JNIEnv* env, jclass clazz, jlong ptr, jint size)
{
  if (ptr == 0 || size <= 0) {
    return (*env)->NewByteArray(env, 0);
  }

  jbyteArray out = (*env)->NewByteArray(env, (jsize)size);
  if (!out) return NULL;

  const jbyte* src = (const jbyte*)(intptr_t)ptr;
  (*env)->SetByteArrayRegion(env, out, 0, (jsize)size, src);
  return out;
}

JNIEXPORT jlong JNICALL
Java_com_jci_mediaprocessor_media_1processor_MediaProcessorPlugin_getANativeWindow
  (JNIEnv* env, jclass clazz, jobject surface)
{
  if (!surface) return 0;
  jobject globalRef = (*env)->NewGlobalRef(env, surface);
  return (jlong)globalRef;
}

JNIEXPORT void JNICALL
Java_com_jci_mediaprocessor_media_1processor_MediaProcessorPlugin_releaseNativeWindow
  (JNIEnv* env, jclass clazz, jlong global_surface_ref)
{
  if (global_surface_ref) {
    (*env)->DeleteGlobalRef(env, (jobject)global_surface_ref);
  }
}
