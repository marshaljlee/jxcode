// JNI bridge to llama.cpp for on-device GGUF inference (arm64-v8a).
//
// Runs in-process rather than as a spawned llama-server: Android forbids
// executing binaries out of an app's writable data directory, so the server
// approach the macOS build uses is not available here.
//
// The prompt is built with llama_chat_apply_template and the model's own
// embedded template, which is the same "auto chat template" behaviour pillar 03
// provides on macOS — no per-model template guessing.
#include <jni.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <string>
#include <vector>

#include "llama.h"

#define LOG_TAG "JXCodeLlama"
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

struct JxSession {
    llama_model *model = nullptr;
    llama_context *ctx = nullptr;
    const llama_vocab *vocab = nullptr;
    llama_sampler *sampler = nullptr;
    int32_t n_batch = 512;
    std::atomic<bool> stop{false};
};

JavaVM *g_vm = nullptr;

JxSession *as_session(jlong handle) { return reinterpret_cast<JxSession *>(handle); }

/** Emits one decoded token to Kotlin. Attaches the calling thread if needed. */
void emit(JNIEnv *env, jobject sink, const std::string &piece) {
    if (sink == nullptr || piece.empty() || env == nullptr) return;
    jclass cls = env->GetObjectClass(sink);
    if (cls == nullptr) return;
    jmethodID method = env->GetMethodID(cls, "onToken", "(Ljava/lang/String;)V");
    if (method == nullptr) {
        env->DeleteLocalRef(cls);
        return;
    }
    jstring value = env->NewStringUTF(piece.c_str());
    env->CallVoidMethod(sink, method, value);
    env->DeleteLocalRef(value);
    env->DeleteLocalRef(cls);
}

} // namespace

extern "C" {

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *) {
    g_vm = vm;
    return JNI_VERSION_1_6;
}

JNIEXPORT jlong JNICALL
Java_com_jxcode_android_llama_LlamaBridge_nativeLoad(
        JNIEnv *env, jclass, jstring jpath, jint contextSize, jint threads) {
    const char *path = env->GetStringUTFChars(jpath, nullptr);
    if (path == nullptr) return 0L;
    std::string modelPath(path);
    env->ReleaseStringUTFChars(jpath, path);

    static std::atomic<bool> backendReady{false};
    if (!backendReady.exchange(true)) {
        llama_backend_init();
    }

    auto *session = new JxSession();

    llama_model_params modelParams = llama_model_default_params();
    // CPU only in this build: there is no Metal here, and OpenCL/Vulkan
    // backends are device-dependent. offload = 0 keeps behaviour predictable.
    modelParams.n_gpu_layers = 0;

    session->model = llama_model_load_from_file(modelPath.c_str(), modelParams);
    if (session->model == nullptr) {
        LOGE("failed to load %s", modelPath.c_str());
        delete session;
        return 0L;
    }

    llama_context_params ctxParams = llama_context_default_params();
    ctxParams.n_ctx = contextSize > 0 ? contextSize : 4096;
    // Big core count is counterproductive on a phone: big.LITTLE means the
    // little cores slow the fastest thread down, and thermals follow.
    ctxParams.n_threads = std::max(1, std::min<int>(threads > 0 ? threads : 4, 4));
    ctxParams.n_batch = 512;
    session->n_batch = ctxParams.n_batch;

    session->ctx = llama_init_from_model(session->model, ctxParams);
    if (session->ctx == nullptr) {
        LOGE("failed to create context");
        llama_model_free(session->model);
        delete session;
        return 0L;
    }

    session->vocab = llama_model_get_vocab(session->model);

    llama_sampler_chain_params samplerParams = llama_sampler_chain_default_params();
    session->sampler = llama_sampler_chain_init(samplerParams);
    llama_sampler_chain_add(session->sampler, llama_sampler_init_top_p(0.95f, 1));
    llama_sampler_chain_add(session->sampler, llama_sampler_init_temp(0.8f));
    // dist must be the last sampler in the chain.
    llama_sampler_chain_add(session->sampler, llama_sampler_init_dist(0));

    LOGI("loaded %s (ctx=%d)", modelPath.c_str(), ctxParams.n_ctx);
    return reinterpret_cast<jlong>(session);
}

JNIEXPORT void JNICALL
Java_com_jxcode_android_llama_LlamaBridge_nativeFree(JNIEnv *, jclass, jlong handle) {
    JxSession *session = as_session(handle);
    if (session == nullptr) return;
    if (session->sampler) llama_sampler_free(session->sampler);
    if (session->ctx) llama_free(session->ctx);
    if (session->model) llama_model_free(session->model);
    delete session;
}

JNIEXPORT void JNICALL
Java_com_jxcode_android_llama_LlamaBridge_nativeStop(JNIEnv *, jclass, jlong handle) {
    JxSession *session = as_session(handle);
    if (session != nullptr) session->stop.store(true);
}

JNIEXPORT jlong JNICALL
Java_com_jxcode_android_llama_LlamaBridge_nativeMemory(JNIEnv *, jclass, jlong handle) {
    JxSession *session = as_session(handle);
    if (session == nullptr || session->model == nullptr) return 0L;
    return static_cast<jlong>(llama_model_size(session->model));
}

JNIEXPORT jstring JNICALL
Java_com_jxcode_android_llama_LlamaBridge_nativeChat(
        JNIEnv *env, jclass, jlong handle,
        jobjectArray jroles, jobjectArray jcontents,
        jint maxTokens, jobject sink) {
    JxSession *session = as_session(handle);
    if (session == nullptr || session->ctx == nullptr) {
        return env->NewStringUTF("");
    }
    session->stop.store(false);

    jsize count = env->GetArrayLength(jroles);
    std::vector<std::string> roles;
    std::vector<std::string> contents;
    roles.reserve(count);
    contents.reserve(count);
    for (jsize i = 0; i < count; i++) {
        jstring jrole = (jstring) env->GetObjectArrayElement(jroles, i);
        jstring jcontent = (jstring) env->GetObjectArrayElement(jcontents, i);
        const char *roleChars = env->GetStringUTFChars(jrole, nullptr);
        const char *contentChars = jcontent ? env->GetStringUTFChars(jcontent, nullptr) : nullptr;
        roles.emplace_back(roleChars ? roleChars : "user");
        contents.emplace_back(contentChars ? contentChars : "");
        if (roleChars) env->ReleaseStringUTFChars(jrole, roleChars);
        if (contentChars) env->ReleaseStringUTFChars(jcontent, contentChars);
        env->DeleteLocalRef(jrole);
        if (jcontent) env->DeleteLocalRef(jcontent);
    }

    std::vector<llama_chat_message> messages;
    messages.reserve(roles.size());
    for (size_t i = 0; i < roles.size(); i++) {
        messages.push_back({roles[i].c_str(), contents[i].c_str()});
    }

    // nullptr template -> the model's own embedded template.
    std::vector<char> buffer(16384);
    int32_t formatted = llama_chat_apply_template(
            nullptr, messages.data(), messages.size(), true, buffer.data(), (int32_t) buffer.size());
    if (formatted > (int32_t) buffer.size()) {
        buffer.resize(formatted + 1);
        formatted = llama_chat_apply_template(
                nullptr, messages.data(), messages.size(), true, buffer.data(), (int32_t) buffer.size());
    }
    std::string prompt;
    if (formatted > 0) {
        prompt.assign(buffer.data(), (size_t) formatted);
    } else {
        // No template in the model: fall back to a plain concatenation rather
        // than failing, so a model without metadata still answers.
        for (size_t i = 0; i < roles.size(); i++) {
            prompt += roles[i] + ": " + contents[i] + "\n";
        }
        prompt += "assistant:";
    }

    // Tokenize: first call sizes the buffer, second fills it.
    int32_t tokenCount = -llama_tokenize(session->vocab, prompt.data(), (int32_t) prompt.size(),
                                         nullptr, 0, true, true);
    if (tokenCount <= 0) {
        LOGE("tokenize failed");
        return env->NewStringUTF("");
    }
    std::vector<llama_token> tokens((size_t) tokenCount);
    int32_t written = llama_tokenize(session->vocab, prompt.data(), (int32_t) prompt.size(),
                                     tokens.data(), (int32_t) tokens.size(), true, true);
    if (written <= 0) {
        return env->NewStringUTF("");
    }
    tokens.resize((size_t) written);

    // Prompt, chunked so a long context cannot exceed n_batch.
    for (int32_t offset = 0; offset < (int32_t) tokens.size(); offset += session->n_batch) {
        int32_t chunk = std::min<int32_t>(session->n_batch, (int32_t) tokens.size() - offset);
        llama_batch batch = llama_batch_get_one(tokens.data() + offset, chunk);
        if (llama_decode(session->ctx, batch) != 0) {
            LOGE("prompt decode failed at %d", offset);
            return env->NewStringUTF("");
        }
    }

    std::string result;
    int32_t budget = maxTokens > 0 ? maxTokens : 512;
    for (int32_t step = 0; step < budget; step++) {
        if (session->stop.load()) break;

        llama_token id = llama_sampler_sample(session->sampler, session->ctx, -1);
        if (llama_vocab_is_eog(session->vocab, id)) break;

        char piece[256];
        int32_t length = llama_token_to_piece(session->vocab, id, piece, sizeof(piece), 0, false);
        if (length > 0) {
            std::string text(piece, (size_t) length);
            result += text;
            emit(env, sink, text);
        }

        llama_batch batch = llama_batch_get_one(&id, 1);
        if (llama_decode(session->ctx, batch) != 0) break;
    }

    return env->NewStringUTF(result.c_str());
}

} // extern "C"
