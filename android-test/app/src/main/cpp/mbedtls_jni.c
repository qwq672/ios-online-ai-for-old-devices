/**
 * mbedtls_jni.c — Android JNI wrapper for mbedTLS HTTP client
 * v261116-7: mbedTLS 双选项 — Android 2.3 上系统不支持 TLS 1.2，用 mbedTLS 自带栈
 *
 * 编译条件: HAS_MBEDTLS=1（CMakeLists.txt 检测到 mbedTLS 源码时定义）
 * 没有 mbedTLS 时此文件不参与编译（CMake 条件编译）
 *
 * 对应 Java 类: com.awa.aichat.network.MbedTLSClient
 * 对应 iOS 类: MbedTLSHTTPClient.m（共享同样的 TLS 流程）
 */

#ifdef HAS_MBEDTLS

#include <jni.h>
#include <android/log.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "mbedtls/net.h"
#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/x509.h"
#include "mbedtls/error.h"

#define TAG "AIAnyWhere/MbedTLS"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  TAG, __VA_ARGS__)

/**
 * Native handle — 持有 mbedTLS 上下文
 * Java 端用 long 持有指针（Android 32 位上 long 是 64 位足够装指针）
 */
typedef struct {
    mbedtls_net_context server_fd;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context ctr_drbg;
    mbedtls_x509_crt cacert;
    int cancelled;
    int connected;
} mbedtls_handle_t;

/**
 * jlong ← → 指针转换（Android NDK 标准 pattern）
 */
static inline mbedtls_handle_t* handle_from_jlong(jlong ptr) {
    return (mbedtls_handle_t*)(intptr_t)ptr;
}

/**
 * Java: static native long nativeCreate()
 * 创建 handle，返回指针（0 = 失败）
 */
JNIEXPORT jlong JNICALL
Java_com_awa_aichat_network_MbedTLSClient_nativeCreate(JNIEnv *env, jclass cls) {
    mbedtls_handle_t* h = (mbedtls_handle_t*)calloc(1, sizeof(mbedtls_handle_t));
    if (!h) {
        LOGE("nativeCreate: calloc failed");
        return 0;
    }
    mbedtls_net_init(&h->server_fd);
    mbedtls_ssl_init(&h->ssl);
    mbedtls_ssl_config_init(&h->conf);
    mbedtls_entropy_init(&h->entropy);
    mbedtls_ctr_drbg_init(&h->ctr_drbg);
    mbedtls_x509_crt_init(&h->cacert);
    return (jlong)(intptr_t)h;
}

/**
 * Java: nativeDestroy(long ptr)
 * 释放所有 mbedTLS 资源
 */
JNIEXPORT void JNICALL
Java_com_awa_aichat_network_MbedTLSClient_nativeDestroy(JNIEnv *env, jclass cls, jlong ptr) {
    mbedtls_handle_t* h = handle_from_jlong(ptr);
    if (!h) return;

    if (h->connected) {
        mbedtls_ssl_close_notify(&h->ssl);
    }
    mbedtls_ssl_free(&h->ssl);
    mbedtls_ssl_config_free(&h->conf);
    mbedtls_entropy_free(&h->entropy);
    mbedtls_ctr_drbg_free(&h->ctr_drbg);
    mbedtls_x509_crt_free(&h->cacert);
    mbedtls_net_free(&h->server_fd);
    free(h);
}

/**
 * Java: nativeCancel(long ptr)
 * 设置 cancelled 标志，让 ssl_read/write 循环退出
 */
JNIEXPORT void JNICALL
Java_com_awa_aichat_network_MbedTLSClient_nativeCancel(JNIEnv *env, jclass cls, jlong ptr) {
    mbedtls_handle_t* h = handle_from_jlong(ptr);
    if (h) h->cancelled = 1;
}

/**
 * Java: nativeConnect(long ptr, String host, int port)
 * 建立 TCP 连接 + TLS 握手
 * 返回 0 = 成功，负数 = 错误（mbedTLS 错误码）
 */
JNIEXPORT jint JNICALL
Java_com_awa_aichat_network_MbedTLSClient_nativeConnect(JNIEnv *env, jclass cls,
                                                          jlong ptr,
                                                          jstring jHost,
                                                          jint port) {
    mbedtls_handle_t* h = handle_from_jlong(ptr);
    if (!h) return -1;

    const char* host = (*env)->GetStringUTFChars(env, jHost, NULL);
    if (!host) return -2;
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", (int)port);

    LOGI("connecting to %s:%s", host, port_str);

    int ret;

    /* 1. 播种 CTR_DRBG */
    const char* pers = "AIAnyWhere";
    if ((ret = mbedtls_ctr_drbg_seed(&h->ctr_drbg, mbedtls_entropy_func,
                                       &h->entropy,
                                       (const unsigned char*)pers, strlen(pers))) != 0) {
        LOGE("ctr_drbg_seed failed: %d", ret);
        (*env)->ReleaseStringUTFChars(env, jHost, host);
        return ret;
    }

    /* 2. TCP 连接 */
    ret = mbedtls_net_connect(&h->server_fd, host, port_str, MBEDTLS_NET_PROTO_TCP);
    if (ret != 0) {
        LOGE("net_connect failed: %d", ret);
        (*env)->ReleaseStringUTFChars(env, jHost, host);
        return ret;
    }
    (*env)->ReleaseStringUTFChars(env, jHost, host);

    /* 3. SSL 配置 */
    if ((ret = mbedtls_ssl_config_defaults(&h->conf,
                                              MBEDTLS_SSL_IS_CLIENT,
                                              MBEDTLS_SSL_TRANSPORT_STREAM,
                                              MBEDTLS_SSL_PRESET_DEFAULT)) != 0) {
        LOGE("ssl_config_defaults failed: %d", ret);
        mbedtls_net_free(&h->server_fd);
        return ret;
    }
    /* 注: VERIFY_NONE 用于兼容老服务器证书链，生产环境应改为 VERIFY_REQUIRED + 加载根证书 */
    mbedtls_ssl_conf_authmode(&h->conf, MBEDTLS_SSL_VERIFY_NONE);
    mbedtls_ssl_conf_rng(&h->conf, mbedtls_ctr_drbg_random, &h->ctr_drbg);
    mbedtls_ssl_conf_ca_chain(&h->conf, &h->cacert, NULL);

    if ((ret = mbedtls_ssl_setup(&h->ssl, &h->conf)) != 0) {
        LOGE("ssl_setup failed: %d", ret);
        mbedtls_net_free(&h->server_fd);
        return ret;
    }

    /* 4. 设置 hostname（SNI） */
    if ((ret = mbedtls_ssl_set_hostname(&h->ssl, host)) != 0) {
        LOGW("set_hostname failed (non-fatal): %d", ret);
    }

    /* 5. 设置 bio */
    mbedtls_ssl_set_bio(&h->ssl, &h->server_fd,
                          mbedtls_net_send, mbedtls_net_recv, mbedtls_net_recv_timeout);

    /* 6. TLS 握手 — 加 usleep 退避（和 iOS 实现一致） */
    while ((ret = mbedtls_ssl_handshake(&h->ssl)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
            LOGE("ssl_handshake failed: %d", ret);
            goto handshake_fail;
        }
        if (h->cancelled) goto handshake_fail;
        usleep(1000);
    }

    if (h->cancelled) goto handshake_fail;

    h->connected = 1;
    LOGI("TLS handshake OK, cipher: %s", mbedtls_ssl_get_ciphersuite(&h->ssl));
    return 0;

handshake_fail:
    mbedtls_ssl_free(&h->ssl);
    mbedtls_ssl_config_free(&h->conf);
    mbedtls_net_free(&h->server_fd);
    h->connected = 0;
    return ret;
}

/**
 * Java: nativeWrite(long ptr, byte[] data)
 * 通过 TLS 写数据
 * 返回写入字节数，负数 = 错误
 */
JNIEXPORT jint JNICALL
Java_com_awa_aichat_network_MbedTLSClient_nativeWrite(JNIEnv *env, jclass cls,
                                                       jlong ptr,
                                                       jbyteArray jData) {
    mbedtls_handle_t* h = handle_from_jlong(ptr);
    if (!h || !h->connected) return -1;

    jsize len = (*env)->GetArrayLength(env, jData);
    jbyte* data = (*env)->GetByteArrayElements(env, jData, NULL);
    if (!data) return -2;

    int written = 0;
    int want_write_count = 0;
    while (written < len) {
        if (h->cancelled) {
            (*env)->ReleaseByteArrayElements(env, jData, data, JNI_ABORT);
            return -3;
        }
        int ret = mbedtls_ssl_write(&h->ssl,
                                      (const unsigned char*)data + written,
                                      (size_t)(len - written));
        if (ret == MBEDTLS_ERR_SSL_WANT_WRITE || ret == MBEDTLS_ERR_SSL_WANT_READ) {
            want_write_count++;
            if (want_write_count > 50) usleep(10000);
            else usleep(1000);
            if (want_write_count > 1000) {
                LOGE("ssl_write timeout (1000+ WANT_WRITE)");
                (*env)->ReleaseByteArrayElements(env, jData, data, JNI_ABORT);
                return -4;
            }
            continue;
        }
        if (ret <= 0) {
            LOGE("ssl_write failed: %d", ret);
            (*env)->ReleaseByteArrayElements(env, jData, data, JNI_ABORT);
            return ret;
        }
        written += ret;
        want_write_count = 0;
    }

    (*env)->ReleaseByteArrayElements(env, jData, data, JNI_ABORT);
    return written;
}

/**
 * Java: nativeRead(long ptr, byte[] buffer)
 * 通过 TLS 读数据
 * 返回读取字节数，0 = EOF，负数 = 错误
 */
JNIEXPORT jint JNICALL
Java_com_awa_aichat_network_MbedTLSClient_nativeRead(JNIEnv *env, jclass cls,
                                                      jlong ptr,
                                                      jbyteArray jBuffer) {
    mbedtls_handle_t* h = handle_from_jlong(ptr);
    if (!h || !h->connected) return -1;

    jsize len = (*env)->GetArrayLength(env, jBuffer);
    jbyte* buf = (*env)->GetByteArrayElements(env, jBuffer, NULL);
    if (!buf) return -2;

    int ret;
    do {
        if (h->cancelled) {
            (*env)->ReleaseByteArrayElements(env, jBuffer, buf, JNI_ABORT);
            return -3;
        }
        ret = mbedtls_ssl_read(&h->ssl, (unsigned char*)buf, (size_t)len);
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) {
            usleep(1000);
            continue;
        }
        break;
    } while (1);

    if (ret == 0 || ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) {
        (*env)->ReleaseByteArrayElements(env, jBuffer, buf, JNI_ABORT);
        return 0;  /* EOF */
    }
    if (ret < 0) {
        LOGE("ssl_read failed: %d", ret);
        (*env)->ReleaseByteArrayElements(env, jBuffer, buf, JNI_ABORT);
        return ret;
    }

    (*env)->ReleaseByteArrayElements(env, jBuffer, buf, 0);
    return ret;
}

#endif /* HAS_MBEDTLS */
