#ifndef MEDIA_PROCESSOR_GLUE_H
#define MEDIA_PROCESSOR_GLUE_H

#include <jni.h>

#ifdef __cplusplus
extern "C" {
#endif

JNIEXPORT jbyteArray JNICALL
Java_com_jci_mediaprocessor_media_1processor_BaseRenderer_getBuffer(
    JNIEnv* env, jclass clazz, jlong ptr, jint size);

JNIEXPORT jlong JNICALL
Java_com_jci_mediaprocessor_media_1processor_MediaProcessorPlugin_getANativeWindow(
    JNIEnv* env, jclass clazz, jobject surface);

JNIEXPORT void JNICALL
Java_com_jci_mediaprocessor_media_1processor_MediaProcessorPlugin_releaseNativeWindow(
    JNIEnv* env, jclass clazz, jlong globalSurfaceRef);

#ifdef __cplusplus
}
#endif

#endif // MEDIA_PROCESSOR_GLUE_H
