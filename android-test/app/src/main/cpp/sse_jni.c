/**
 * sse_jni.c — JNI wrapper for shared SSE parser
 * v261113: Android JNI 桥接层，让 Java 调用共享 C 的 SSE 解析器
 *
 * Java 侧用法：
 *   SSEParser parser = new SSEParser(callback);
 *   parser.feed(rawBytes);   // 收到网络数据时调
 *   parser.destroy();        // 结束时调
 */

#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>

#include "sse.h"

#define TAG "AIAnyWhere/SSE"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

/* JNI 回调：把 C callback 转成 Java callback */
typedef struct {
    JavaVM* jvm;
    jobject callback_ref;     /* GlobalRef to SSEParser.Callback */
    jmethodID callback_method; /* Callback.onData(String, boolean) */
} jni_callback_data;

/* C callback → 调 Java */
static void jni_callback(const char* data, size_t len, int done, void* user) {
    jni_callback_data* cd = (jni_callback_data*)user;
    if (!cd || !cd->jvm || !cd->callback_ref) return;

    JNIEnv* env;
    int attached = 0;
    if ((*cd->jvm)->GetEnv(cd->jvm, (void**)&env, JNI_VERSION_1_4) != JNI_OK) {
        if ((*cd->jvm)->AttachCurrentThread(cd->jvm, &env, NULL) != JNI_OK) return;
        attached = 1;
    }

    /* 创建 Java String */
    jstring jdata = NULL;
    if (data && len > 0) {
        jdata = (*env)->NewStringUTF(env, data);
    } else {
        jdata = (*env)->NewStringUTF(env, "");
    }

    /* 调 Java callback */
    (*env)->CallVoidMethod(env, cd->callback_ref, cd->callback_method, jdata, done ? JNI_TRUE : JNI_FALSE);

    (*env)->DeleteLocalRef(env, jdata);

    if (attached) {
        (*cd->jvm)->DetachCurrentThread(cd->jvm);
    }
}

/* JNI methods */

JNIEXPORT jlong JNICALL
Java_com_awa_aichat_network_SSEParser_nativeCreate(JNIEnv* env, jobject thiz, jobject callback) {
    if (!callback) return 0;

    JavaVM* jvm;
    (*env)->GetJavaVM(env, &jvm);

    jni_callback_data* cd = (jni_callback_data*)calloc(1, sizeof(jni_callback_data));
    if (!cd) return 0;
    cd->jvm = jvm;
    cd->callback_ref = (*env)->NewGlobalRef(env, callback);

    jclass cbClass = (*env)->GetObjectClass(env, callback);
    cd->callback_method = (*env)->GetMethodID(env, cbClass, "onData", "(Ljava/lang/String;Z)V");
    (*env)->DeleteLocalRef(env, cbClass);

    if (!cd->callback_method) {
        LOGI("Callback method onData not found");
        (*env)->DeleteGlobalRef(env, cd->callback_ref);
        free(cd);
        return 0;
    }

    sse_parser* p = sse_parser_create(jni_callback, cd);
    if (!p) {
        (*env)->DeleteGlobalRef(env, cd->callback_ref);
        free(cd);
        return 0;
    }

    /* Pack parser ptr (high 32) + callback_data ptr (low 32) into one jlong */
    jlong result = ((jlong)(intptr_t)p << 32) | ((jlong)(intptr_t)cd & 0xFFFFFFFFL);
    return result;
}

JNIEXPORT void JNICALL
Java_com_awa_aichat_network_SSEParser_nativeFeed(JNIEnv* env, jobject thiz, jlong ptr, jbyteArray data) {
    sse_parser* p = (sse_parser*)ptr;
    if (!p || !data) return;

    jsize len = (*env)->GetArrayLength(env, data);
    if (len <= 0) return;

    jbyte* bytes = (*env)->GetByteArrayElements(env, data, NULL);
    if (!bytes) return;

    sse_parser_feed(p, (const char*)bytes, (size_t)len);

    (*env)->ReleaseByteArrayElements(env, data, bytes, JNI_ABORT);
}

JNIEXPORT void JNICALL
Java_com_awa_aichat_network_SSEParser_nativeReset(JNIEnv* env, jobject thiz, jlong ptr) {
    sse_parser* p = (sse_parser*)ptr;
    if (p) sse_parser_reset(p);
}

JNIEXPORT void JNICALL
Java_com_awa_aichat_network_SSEParser_nativeDestroy(JNIEnv* env, jobject thiz, jlong ptr) {
    sse_parser* p = (sse_parser*)ptr;
    if (!p) return;

    /* 获取 callback data 并释放 */
    /* 注意：sse_parser 内部持有 callback_data 指针，
       但我们无法直接获取它。需要在 Java 侧也保存引用。 */
    sse_parser_destroy(p);
}

JNIEXPORT void JNICALL
Java_com_awa_aichat_network_SSEParser_nativeDestroyWithCallback(JNIEnv* env, jobject thiz, jlong ptr, jlong callback_ptr) {
    sse_parser* p = (sse_parser*)ptr;
    if (!p) return;

    sse_parser_destroy(p);

    /* 释放 callback data */
    jni_callback_data* cd = (jni_callback_data*)callback_ptr;
    if (cd) {
        if (cd->callback_ref && cd->jvm) {
            JNIEnv* cb_env;
            int attached = 0;
            if ((*cd->jvm)->GetEnv(cd->jvm, (void**)&cb_env, JNI_VERSION_1_4) != JNI_OK) {
                if ((*cd->jvm)->AttachCurrentThread(cd->jvm, &cb_env, NULL) == JNI_OK) {
                    attached = 1;
                }
            }
            if (cb_env) {
                (*cb_env)->DeleteGlobalRef(cb_env, cd->callback_ref);
            }
            if (attached) {
                (*cd->jvm)->DetachCurrentThread(cd->jvm);
            }
        }
        free(cd);
    }
}
