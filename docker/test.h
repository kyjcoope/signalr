#ifndef MEDIA_PROCESSOR_GLUE_H
#define MEDIA_PROCESSOR_GLUE_H

#include <jni.h>

#ifdef __cplusplus
extern "C" {
#endif

// Wrap native memory [ptr, ptr+size) as a direct java.nio.ByteBuffer (no copy).
JNIEXPORT jobject JNICALL
Java_com_jci_mediaprocessor_media_1processor_BaseRenderer_getBufferDirect(
    JNIEnv* env, jclass clazz, jlong ptr, jint size);

// Return a global ref to the Java Surface (you can ANativeWindow_fromSurface() in native).
JNIEXPORT jlong JNICALL
Java_com_jci_mediaprocessor_media_1processor_MediaProcessorPlugin_getANativeWindow(
    JNIEnv* env, jclass clazz, jobject surface);

// Delete the global ref created above. Call during dispose.
JNIEXPORT void JNICALL
Java_com_jci_mediaprocessor_media_1processor_MediaProcessorPlugin_releaseNativeWindow(
    JNIEnv* env, jclass clazz, jlong global_surface_ref);

#ifdef __cplusplus
}
#endif

#endif // MEDIA_PROCESSOR_GLUE_H
