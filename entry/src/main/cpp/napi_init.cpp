#include "napi/native_api.h"
#include "hilog/log.h"
#include "libtailscale_go.h"
#include "native_boundary.h"
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <fcntl.h>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unistd.h>
#include <utility>
#include <vector>

namespace {
constexpr size_t kMaxInterfaceNameBytes = 64;
constexpr size_t kMaxPathDiagBytes = 2048;
constexpr size_t kMaxPathBytes = 4096;
constexpr size_t kMaxSmallArgBytes = 4096;
constexpr size_t kMaxAuthKeyBytes = 4096;
constexpr size_t kMaxDnsRuntimeBytes = 16384;
constexpr size_t kMaxJsonRequestBytes = 256 * 1024;

constexpr size_t kTransferLaneMaxInFlight = 2;
constexpr size_t kProbeLaneMaxInFlight = 1;

template <napi_callback Callback>
napi_value GuardCallback(napi_env env, napi_callback_info info) noexcept
{
    return mesharc::GuardNativeCall([&]() { return Callback(env, info); }, [&]() noexcept -> napi_value {
        napi_throw_error(env, nullptr, "Native backend operation failed");
        return nullptr;
    });
}

struct OwnedTunDescriptor {
    int fd;
    explicit OwnedTunDescriptor(int value) noexcept : fd(value) {}
    OwnedTunDescriptor(const OwnedTunDescriptor&) = delete;
    OwnedTunDescriptor& operator=(const OwnedTunDescriptor&) = delete;
    OwnedTunDescriptor(OwnedTunDescriptor&& other) noexcept : fd(other.fd) { other.fd = -1; }
    ~OwnedTunDescriptor()
    {
        if (fd >= 0) {
            close(fd);
        }
    }
};

struct ScopedStringScrub {
    std::string& value;
    explicit ScopedStringScrub(std::string& target) noexcept : value(target) {}
    ScopedStringScrub(const ScopedStringScrub&) = delete;
    ScopedStringScrub& operator=(const ScopedStringScrub&) = delete;
    ~ScopedStringScrub() noexcept { mesharc::ScrubString(value); }
};

bool ReadBoundedUtf8Arg(
    napi_env env,
    napi_value value,
    size_t maxBytes,
    bool allowEmpty,
    std::string& out,
    const char* typeOrRangeError,
    const char* readError = nullptr,
    bool scrub = false)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok ||
        (!allowEmpty && length == 0) || length > maxBytes) {
        napi_throw_type_error(env, nullptr, typeOrRangeError);
        return false;
    }
    if (length == 0) {
        out.clear();
        return true;
    }
    if (scrub) {
        std::vector<char> buffer(length + 1, '\0');
        mesharc::ScopedScrubBuffer scrubGuard(buffer);
        size_t copied = 0;
        if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &copied) != napi_ok) {
            if (readError != nullptr) {
                napi_throw_error(env, nullptr, readError);
            } else {
                napi_throw_type_error(env, nullptr, typeOrRangeError);
            }
            return false;
        }
        if (copied != length || mesharc::HasEmbeddedNull(buffer.data(), copied)) {
            napi_throw_type_error(env, nullptr, typeOrRangeError);
            return false;
        }
        out.assign(buffer.data(), copied);
        return true;
    }

    out.resize(length);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, &out[0], length + 1, &copied) != napi_ok) {
        out.clear();
        if (readError != nullptr) {
            napi_throw_error(env, nullptr, readError);
        } else {
            napi_throw_type_error(env, nullptr, typeOrRangeError);
        }
        return false;
    }
    if (copied != length || mesharc::HasEmbeddedNull(out.data(), copied)) {
        out.clear();
        napi_throw_type_error(env, nullptr, typeOrRangeError);
        return false;
    }
    return true;
}

void RejectDeferredWithError(napi_env env, napi_deferred deferred, const char* errorText) noexcept
{
    napi_value message = nullptr;
    napi_value error = nullptr;
    napi_create_string_utf8(env, errorText, NAPI_AUTO_LENGTH, &message);
    napi_create_error(env, nullptr, message, &error);
    napi_reject_deferred(env, deferred, error);
}

napi_value CallSyncString(
    napi_env env, char* (*producer)(), const char* nullError, const char* convertError)
{
    char* message = producer();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, nullError);
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, convertError);
        return nullptr;
    }
    return result;
}

// Resolves non-blocking cancel endpoints directly on the calling JS thread so
// cancellation can never be starved behind 4 saturated libuv workers.
napi_value CreateImmediateStringPromise(napi_env env, char* (*producer)())
{
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create native backend promise");
        return nullptr;
    }
    std::string result;
    napi_value value = nullptr;
    if (mesharc::CopyNativeString(producer, result, TSFreeString) &&
        napi_create_string_utf8(env, result.c_str(), NAPI_AUTO_LENGTH, &value) == napi_ok) {
        napi_resolve_deferred(env, deferred, value);
    } else {
        RejectDeferredWithError(env, deferred, "Native backend operation failed");
    }
    return promise;
}

// Reserve a new destination without ever opening an existing file for writing.
// ArkTS FileIo.OpenMode does not expose O_EXCL. The caller owns the returned FD.
napi_value CreateExclusiveFile(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "Invalid destination path");
        return nullptr;
    }
    std::string path;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxPathBytes, false, path, "Invalid destination path") ||
        path[0] != '/') {
        if (!path.empty() && path[0] != '/') {
            napi_throw_type_error(env, nullptr, "Invalid destination path");
        }
        return nullptr;
    }
    const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    const int resultCode = fd >= 0 ? fd : -errno;
    napi_value result = nullptr;
    if (napi_create_int32(env, resultCode, &result) != napi_ok) {
        if (fd >= 0) {
            close(fd);
        }
        napi_throw_error(env, nullptr, "Failed to return destination descriptor");
        return nullptr;
    }
    return result;
}

enum class WorkLane {
    FastControl,
    Transfer,
    Probe
};

struct LaneTask {
    napi_env env;
    napi_async_work work;
    void (*failAndDestroy)(napi_env env, void* payload) noexcept;
    void* payload;
};

std::mutex g_laneMutex;
mesharc::BoundedWorkQueue<LaneTask> g_transferLane(kTransferLaneMaxInFlight);
mesharc::BoundedWorkQueue<LaneTask> g_probeLane(kProbeLaneMaxInFlight);

mesharc::BoundedWorkQueue<LaneTask>* GetWorkLaneQueue(WorkLane lane) noexcept
{
    switch (lane) {
        case WorkLane::Transfer:
            return &g_transferLane;
        case WorkLane::Probe:
            return &g_probeLane;
        case WorkLane::FastControl:
            return nullptr;
    }
    return nullptr;
}

bool SubmitToWorkLane(
    napi_env env,
    WorkLane lane,
    napi_async_work work,
    void (*failAndDestroy)(napi_env env, void* payload) noexcept,
    void* payload)
{
    mesharc::BoundedWorkQueue<LaneTask>* queue = GetWorkLaneQueue(lane);
    if (queue == nullptr) {
        return napi_queue_async_work(env, work) == napi_ok;
    }

    bool queueNow = false;
    {
        std::lock_guard<std::mutex> lock(g_laneMutex);
        queueNow = queue->TryAcquireOrEnqueue(LaneTask{env, work, failAndDestroy, payload});
    }
    if (!queueNow) {
        return true;
    }
    if (napi_queue_async_work(env, work) == napi_ok) {
        return true;
    }
    {
        std::lock_guard<std::mutex> lock(g_laneMutex);
        queue->ReleaseOnImmediateQueueFailure();
    }
    return false;
}

void ReleaseWorkLaneSlot(WorkLane lane) noexcept
{
    mesharc::BoundedWorkQueue<LaneTask>* queue = GetWorkLaneQueue(lane);
    if (queue == nullptr) {
        return;
    }
    for (;;) {
        LaneTask next{};
        {
            std::lock_guard<std::mutex> lock(g_laneMutex);
            if (!queue->ReleaseAndTakeNext(next)) {
                return;
            }
        }
        if (napi_queue_async_work(next.env, next.work) == napi_ok) {
            return;
        }
        next.failAndDestroy(next.env, next.payload);
    }
}

using AsyncStringFunction = std::function<char*()>;

struct AsyncStringWork {
    napi_env env;
    napi_async_work work;
    napi_deferred deferred;
    WorkLane lane;
    AsyncStringFunction function;
    std::string result;
    bool succeeded;
};

enum class AsyncInputOperation {
    LoginWithAuthKey,
    NetworkChanged,
    PathDiagnostic,
    DnsRuntime,
    SetExitNode,
    SetNetworkSetting,
    PeerConnectivity,
    SunshineProbe,
    MediaServiceProbe,
    TaildropSend,
    TaildropReceive,
    TaildriveList,
    TaildriveStat,
    TaildriveMutate,
    TaildriveDownload,
    TaildriveManualDownload,
    TaildriveUpload
};

WorkLane LaneForInputOperation(AsyncInputOperation operation) noexcept
{
    switch (operation) {
        case AsyncInputOperation::TaildropSend:
        case AsyncInputOperation::TaildropReceive:
        case AsyncInputOperation::TaildriveMutate:
        case AsyncInputOperation::TaildriveDownload:
        case AsyncInputOperation::TaildriveManualDownload:
        case AsyncInputOperation::TaildriveUpload:
            return WorkLane::Transfer;
        case AsyncInputOperation::PeerConnectivity:
        case AsyncInputOperation::SunshineProbe:
        case AsyncInputOperation::MediaServiceProbe:
        case AsyncInputOperation::TaildriveList:
        case AsyncInputOperation::TaildriveStat:
            return WorkLane::Probe;
        case AsyncInputOperation::LoginWithAuthKey:
        case AsyncInputOperation::NetworkChanged:
        case AsyncInputOperation::PathDiagnostic:
        case AsyncInputOperation::DnsRuntime:
        case AsyncInputOperation::SetExitNode:
        case AsyncInputOperation::SetNetworkSetting:
            return WorkLane::FastControl;
    }
    return WorkLane::FastControl;
}

struct AsyncInputWork {
    napi_async_work work;
    napi_deferred deferred;
    WorkLane lane;
    AsyncInputOperation operation;
    std::string input;
    bool enabled;
    std::string result;
    bool succeeded;

    AsyncInputWork(
        napi_deferred deferredValue,
        WorkLane laneValue,
        AsyncInputOperation opValue,
        std::string&& inputValue,
        bool enabledValue)
        : work(nullptr),
          deferred(deferredValue),
          lane(laneValue),
          operation(opValue),
          input(std::move(inputValue)),
          enabled(enabledValue),
          result(),
          succeeded(false) {}

    ~AsyncInputWork() noexcept
    {
        if (operation == AsyncInputOperation::LoginWithAuthKey) {
            mesharc::ScrubString(input);
        }
    }
};

void FailDeferredAsyncStringWork(napi_env env, void* payload) noexcept
{
    auto* work = static_cast<AsyncStringWork*>(payload);
    RejectDeferredWithError(env, work->deferred, "Native backend operation failed");
    if (work->work != nullptr) {
        napi_delete_async_work(env, work->work);
    }
    delete work;
}

void FailDeferredAsyncInputWork(napi_env env, void* payload) noexcept
{
    auto* work = static_cast<AsyncInputWork*>(payload);
    RejectDeferredWithError(env, work->deferred, "Native backend update failed");
    if (work->work != nullptr) {
        napi_delete_async_work(env, work->work);
    }
    delete work;
}

void ExecuteAsyncString(napi_env env, void* data)
{
    (void)env;
    auto* work = static_cast<AsyncStringWork*>(data);
    work->succeeded = mesharc::CopyNativeString(work->function, work->result, TSFreeString);
}

void CompleteAsyncString(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<AsyncStringWork*>(data);
    const WorkLane completedLane = work->lane;
    napi_value value = nullptr;
    if (status == napi_ok && work->succeeded &&
        napi_create_string_utf8(env, work->result.c_str(), NAPI_AUTO_LENGTH, &value) == napi_ok) {
        napi_resolve_deferred(env, work->deferred, value);
    } else {
        RejectDeferredWithError(env, work->deferred, "Native backend operation failed");
    }
    napi_delete_async_work(env, work->work);
    delete work;
    ReleaseWorkLaneSlot(completedLane);
}

napi_value CreateAsyncStringPromise(
    napi_env env,
    AsyncStringFunction function,
    const char* resourceName,
    WorkLane lane = WorkLane::FastControl)
{
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create native backend promise");
        return nullptr;
    }
    auto* work = new AsyncStringWork{env, nullptr, deferred, lane, std::move(function), "", false};
    napi_value resource = nullptr;
    if (napi_create_string_utf8(env, resourceName, NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, ExecuteAsyncString, CompleteAsyncString, work, &work->work) != napi_ok ||
        !SubmitToWorkLane(env, lane, work->work, FailDeferredAsyncStringWork, work)) {
        if (work->work != nullptr) {
            napi_delete_async_work(env, work->work);
        }
        delete work;
        napi_throw_error(env, nullptr, "Failed to queue native backend operation");
        return nullptr;
    }
    return promise;
}

void ExecuteAsyncInput(napi_env env, void* data)
{
    (void)env;
    auto* work = static_cast<AsyncInputWork*>(data);
    work->succeeded = mesharc::CopyNativeString([work]() -> char* {
        char* arg = const_cast<char*>(work->input.c_str());
        switch (work->operation) {
            case AsyncInputOperation::LoginWithAuthKey:
                return TSBackendLoginWithAuthKey(arg);
            case AsyncInputOperation::NetworkChanged:
                return TSBackendNetworkChanged(arg);
            case AsyncInputOperation::PathDiagnostic:
                return TSBackendPathDiagnostic(arg);
            case AsyncInputOperation::DnsRuntime:
                return TSBackendDNSRuntime(arg);
            case AsyncInputOperation::SetExitNode:
                return TSBackendSetExitNode(arg);
            case AsyncInputOperation::SetNetworkSetting:
                return TSBackendSetNetworkSetting(arg, work->enabled ? 1 : 0);
            case AsyncInputOperation::PeerConnectivity:
                return TSBackendPeerConnectivity(arg);
            case AsyncInputOperation::SunshineProbe:
                return TSBackendSunshineProbe(arg);
            case AsyncInputOperation::MediaServiceProbe:
                return TSBackendMediaServiceProbe(arg);
            case AsyncInputOperation::TaildropSend:
                return TSBackendTaildropSend(arg);
            case AsyncInputOperation::TaildropReceive:
                return TSBackendTaildropReceive(arg);
            case AsyncInputOperation::TaildriveList:
                return TSBackendTaildriveList(arg);
            case AsyncInputOperation::TaildriveStat:
                return TSBackendTaildriveStat(arg);
            case AsyncInputOperation::TaildriveMutate:
                return TSBackendTaildriveMutate(arg);
            case AsyncInputOperation::TaildriveDownload:
                return TSBackendTaildriveDownload(arg);
            case AsyncInputOperation::TaildriveManualDownload:
                return TSBackendTaildriveManualDownload(arg);
            case AsyncInputOperation::TaildriveUpload:
                return TSBackendTaildriveUpload(arg);
        }
        return nullptr;
    }, work->result, TSFreeString);
    if (work->operation == AsyncInputOperation::LoginWithAuthKey) {
        // Erase immediately after the Go call completes, in addition to ~AsyncInputWork().
        mesharc::ScrubString(work->input);
    }
}

void CompleteAsyncInput(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<AsyncInputWork*>(data);
    const WorkLane completedLane = work->lane;
    napi_value value = nullptr;
    if (status == napi_ok && work->succeeded &&
        napi_create_string_utf8(env, work->result.c_str(), NAPI_AUTO_LENGTH, &value) == napi_ok) {
        napi_resolve_deferred(env, work->deferred, value);
    } else {
        RejectDeferredWithError(env, work->deferred, "Native backend update failed");
    }
    napi_delete_async_work(env, work->work);
    delete work;
    ReleaseWorkLaneSlot(completedLane);
}

napi_value CreateAsyncInputPromise(
    napi_env env,
    AsyncInputOperation operation,
    std::string&& input,
    bool enabled,
    const char* resourceName)
{
    const WorkLane lane = LaneForInputOperation(operation);
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        if (operation == AsyncInputOperation::LoginWithAuthKey) {
            mesharc::ScrubString(input);
        }
        napi_throw_error(env, nullptr, "Failed to create native backend update promise");
        return nullptr;
    }
    auto* work = new AsyncInputWork(deferred, lane, operation, std::move(input), enabled);
    napi_value resource = nullptr;
    if (napi_create_string_utf8(env, resourceName, NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, ExecuteAsyncInput, CompleteAsyncInput, work, &work->work) != napi_ok ||
        !SubmitToWorkLane(env, lane, work->work, FailDeferredAsyncInputWork, work)) {
        if (work->work != nullptr) {
            napi_delete_async_work(env, work->work);
        }
        delete work;
        napi_throw_error(env, nullptr, "Failed to queue native backend update");
        return nullptr;
    }
    return promise;
}

napi_value BackendSetExitNodeAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendSetExitNodeAsync requires one selection");
        return nullptr;
    }
    std::string selection;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxSmallArgBytes, true, selection,
            "Exit-node selection must be a string", "Failed to read the exit-node selection")) {
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::SetExitNode, std::move(selection), false, "TailscaleBackendSetExitNode");
}

napi_value BackendSetNetworkSettingAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
        napi_throw_type_error(env, nullptr, "backendSetNetworkSettingAsync requires a key and boolean value");
        return nullptr;
    }
    std::string key;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxSmallArgBytes, true, key,
            "Network setting key must be a string", "Failed to read the network setting key")) {
        return nullptr;
    }
    bool enabled = false;
    if (napi_get_value_bool(env, args[1], &enabled) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Network setting value must be a boolean");
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::SetNetworkSetting, std::move(key), enabled, "TailscaleBackendSetNetworkSetting");
}

napi_value BackendPeerConnectivityAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendPeerConnectivityAsync requires one peer key");
        return nullptr;
    }
    std::string key;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxSmallArgBytes, true, key,
            "Peer key must be a string", "Failed to read the peer key")) {
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::PeerConnectivity, std::move(key), false, "TailscaleBackendPeerConnectivity");
}

napi_value BackendNetworkChangedAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendNetworkChangedAsync requires an interface name");
        return nullptr;
    }
    std::string name;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxInterfaceNameBytes, true, name,
            "backendNetworkChangedAsync requires an interface name", "Failed to read the interface name")) {
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::NetworkChanged, std::move(name), false, "TailscaleBackendNetworkChanged");
}

napi_value BackendPathDiagnosticAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendPathDiagnosticAsync requires an interface name");
        return nullptr;
    }
    std::string command;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxPathDiagBytes, true, command,
            "backendPathDiagnosticAsync requires an interface name", "Failed to read the interface name")) {
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::PathDiagnostic, std::move(command), false, "MeshArcPathDiagnostic");
}

napi_value BackendDnsRuntimeAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "Invalid DNS runtime request");
        return nullptr;
    }
    std::string input;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxDnsRuntimeBytes, true, input,
            "Invalid DNS runtime request", "Failed to read DNS runtime request")) {
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::DnsRuntime, std::move(input), false, "MeshArcDnsRuntime");
}

napi_value BackendSunshineProbeAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendSunshineProbeAsync requires one peer key");
        return nullptr;
    }
    std::string key;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxSmallArgBytes, true, key,
            "Peer key must be a string", "Failed to read the peer key")) {
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::SunshineProbe, std::move(key), false, "TailscaleBackendSunshineProbe");
}

napi_value BackendMediaServiceProbeAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendMediaServiceProbeAsync requires one peer key");
        return nullptr;
    }
    std::string key;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxSmallArgBytes, true, key,
            "Peer key must be a string", "Failed to read the peer key")) {
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::MediaServiceProbe, std::move(key), false, "TailscaleBackendMediaServiceProbe");
}

napi_value BackendTaildropSendAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendTaildropSendAsync requires one request");
        return nullptr;
    }
    std::string request;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxJsonRequestBytes, true, request,
            "Taildrop request must be a string", "Failed to read the Taildrop request")) {
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::TaildropSend, std::move(request), false, "TailscaleBackendTaildropSend");
}

napi_value BackendTaildropReceiveAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendTaildropReceiveAsync requires one request");
        return nullptr;
    }
    std::string request;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxJsonRequestBytes, true, request,
            "Taildrop receive request must be a string", "Failed to read the Taildrop receive request")) {
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::TaildropReceive, std::move(request), false, "TailscaleBackendTaildropReceive");
}

napi_value BackendTaildropCancelAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateImmediateStringPromise(env, TSBackendTaildropCancel);
}

napi_value BackendTaildriveRequestAsync(
    napi_env env,
    napi_callback_info info,
    AsyncInputOperation operation,
    const char* argumentError,
    const char* readError,
    const char* resourceName)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, argumentError);
        return nullptr;
    }
    std::string request;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxJsonRequestBytes, true, request,
            "Taildrive request must be a string", readError)) {
        return nullptr;
    }
    return CreateAsyncInputPromise(env, operation, std::move(request), false, resourceName);
}

napi_value BackendTaildriveListAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::TaildriveList,
        "backendTaildriveListAsync requires one request", "Failed to read the Taildrive list request",
        "TailscaleBackendTaildriveList");
}

napi_value BackendTaildriveStatAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::TaildriveStat,
        "backendTaildriveStatAsync requires one request", "Failed to read the Taildrive stat request",
        "TailscaleBackendTaildriveStat");
}

napi_value BackendTaildriveMutateAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::TaildriveMutate,
        "backendTaildriveMutateAsync requires one request", "Failed to read the Taildrive mutation request",
        "TailscaleBackendTaildriveMutate");
}

napi_value BackendTaildriveDownloadAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::TaildriveDownload,
        "backendTaildriveDownloadAsync requires one request", "Failed to read the Taildrive download request",
        "TailscaleBackendTaildriveDownload");
}

napi_value BackendTaildriveUploadAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::TaildriveUpload,
        "backendTaildriveUploadAsync requires one request", "Failed to read the Taildrive upload request",
        "TailscaleBackendTaildriveUpload");
}

napi_value BackendTaildriveManualDownloadAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::TaildriveManualDownload,
        "backendTaildriveManualDownloadAsync requires one request",
        "Failed to read the Taildrive manual download request",
        "TailscaleBackendTaildriveManualDownload");
}

napi_value BackendTaildriveTransferSnapshotAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(
        env, TSBackendTaildriveTransferSnapshot, "TailscaleBackendTaildriveTransferSnapshot");
}

napi_value BackendTaildriveCancelAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateImmediateStringPromise(env, TSBackendTaildriveCancel);
}

napi_value BackendSnapshotAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendSnapshot, "TailscaleBackendSnapshot");
}

napi_value BackendPeerSnapshotAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendPeerSnapshot, "TailscaleBackendPeerSnapshot");
}

napi_value BackendLocalSendRefreshAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(
        env, TSBackendLocalSendRefresh, "TailscaleBackendLocalSendRefresh", WorkLane::Probe);
}

napi_value BackendTaildropIncomingSnapshotAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(
        env, TSBackendTaildropIncomingSnapshot, "TailscaleBackendTaildropIncomingSnapshot");
}

napi_value BackendStopAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendStop, "TailscaleBackendStop");
}

napi_value BackendLogoutAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendLogout, "TailscaleBackendLogout");
}

napi_value BackendAuthURLAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendAuthURL, "TailscaleBackendAuthURL");
}

napi_value BackendLoginWithAuthKeyAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "Invalid device auth key");
        return nullptr;
    }
    std::string secret;
    ScopedStringScrub scrubLocal(secret);
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxAuthKeyBytes, false, secret,
            "Invalid device auth key", nullptr, true)) {
        return nullptr;
    }
    return CreateAsyncInputPromise(env, AsyncInputOperation::LoginWithAuthKey,
        std::move(secret), false, "TailscaleBackendLoginWithAuthKey");
}

napi_value BackendVpnConfigAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendVPNConfig, "TailscaleBackendVpnConfig");
}

napi_value BackendDnsConfigAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendDNSConfig, "TailscaleBackendDnsConfig");
}

napi_value ProbeEngineAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSProbeEngine, "TailscaleEngineProbe", WorkLane::Probe);
}

napi_value BackendPeerProbeAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendPeerProbe, "TailscaleBackendPeerProbe", WorkLane::Probe);
}

napi_value BackendMediaProbeSelfTestAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSMediaProbeSelfTest, "MeshArcMediaProbeSelfTest");
}

napi_value Hello(napi_env env, napi_callback_info info)
{
    (void)info;
    OH_LOG_INFO(LOG_APP, "C++ N-API bridge loaded; calling Go runtime");
    return CallSyncString(env, TSHello,
        "Go bridge returned a null status string",
        "Failed to convert the Go status to an ArkTS string");
}

napi_value ProbeEngine(napi_env env, napi_callback_info info)
{
    (void)info;
    OH_LOG_INFO(LOG_APP, "Initializing Tailscale userspace engine probe");
    return CallSyncString(env, TSProbeEngine,
        "Tailscale engine probe returned a null status string",
        "Failed to convert the Tailscale engine status to an ArkTS string");
}

napi_value BackendStart(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 4) {
        napi_throw_type_error(env, nullptr,
            "backendStart requires state directory, device model, OS version and control server");
        return nullptr;
    }
    std::string stateDir;
    std::string deviceModel;
    std::string osVersion;
    std::string controlURL;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxPathBytes, true, stateDir,
            "backendStart state directory must be a string", "Failed to read the backend state directory") ||
        !ReadBoundedUtf8Arg(env, args[1], kMaxPathBytes, true, deviceModel,
            "backendStart device model must be a string", "Failed to read the backend device model") ||
        !ReadBoundedUtf8Arg(env, args[2], kMaxPathBytes, true, osVersion,
            "backendStart OS version must be a string", "Failed to read the backend OS version") ||
        !ReadBoundedUtf8Arg(env, args[3], kMaxPathBytes, true, controlURL,
            "backendStart control server must be a string", "Failed to read the backend control server")) {
        return nullptr;
    }
    OH_LOG_INFO(LOG_APP, "Starting the persistent Tailscale LocalBackend");
    char* message = TSBackendStart(
        const_cast<char*>(stateDir.c_str()),
        const_cast<char*>(deviceModel.c_str()),
        const_cast<char*>(osVersion.c_str()),
        const_cast<char*>(controlURL.c_str()));
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale backend start returned a null status string");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to convert the Tailscale backend start status");
        return nullptr;
    }
    return result;
}

napi_value BackendStop(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSyncString(env, TSBackendStop,
        "Backend stop returned a null status",
        "Failed to create backend stop status");
}

napi_value BackendLogout(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSyncString(env, TSBackendLogout,
        "Backend logout returned a null status",
        "Failed to create backend logout status");
}

napi_value BackendStatus(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSyncString(env, TSBackendStatus,
        "Tailscale backend status returned a null string",
        "Failed to convert the Tailscale backend status");
}

napi_value BackendAuthURL(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSyncString(env, TSBackendAuthURL,
        "Tailscale login URL is unavailable",
        "Failed to transfer the Tailscale login URL");
}

napi_value BackendVpnConfig(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSyncString(env, TSBackendVPNConfig,
        "Tailscale VPN config is unavailable",
        "Failed to transfer the Tailscale VPN config");
}

napi_value BackendExitNodes(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSyncString(env, TSBackendExitNodes,
        "Exit-node choices are unavailable",
        "Failed to transfer exit-node choices");
}

napi_value BackendPeers(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSyncString(env, TSBackendPeers,
        "Peer summaries are unavailable",
        "Failed to transfer peer summaries");
}

napi_value BackendAccount(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSyncString(env, TSBackendAccount,
        "Account summary is unavailable",
        "Failed to transfer the account summary");
}

napi_value TailscaleVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSyncString(env, TSTailscaleVersion,
        "Tailscale version is unavailable",
        "Failed to transfer the Tailscale version");
}

napi_value BackendNetworkSettings(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSyncString(env, TSBackendNetworkSettings,
        "Network settings are unavailable",
        "Failed to transfer network settings");
}

napi_value BackendSetNetworkSetting(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
        napi_throw_type_error(env, nullptr, "backendSetNetworkSetting requires a key and boolean value");
        return nullptr;
    }
    std::string key;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxSmallArgBytes, true, key,
            "Network setting key must be a string", "Failed to read the network setting key")) {
        return nullptr;
    }
    bool enabled = false;
    if (napi_get_value_bool(env, args[1], &enabled) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Network setting value must be a boolean");
        return nullptr;
    }
    char* message = TSBackendSetNetworkSetting(const_cast<char*>(key.c_str()), enabled ? 1 : 0);
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Network setting update returned a null status");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer network setting update status");
        return nullptr;
    }
    return result;
}

napi_value BackendSetExitNode(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendSetExitNode requires one selection");
        return nullptr;
    }
    std::string selection;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxSmallArgBytes, true, selection,
            "Exit-node selection must be a string", "Failed to read the exit-node selection")) {
        return nullptr;
    }
    char* message = TSBackendSetExitNode(const_cast<char*>(selection.c_str()));
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Exit-node update returned a null status");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer exit-node update status");
        return nullptr;
    }
    return result;
}

napi_value BackendPeerProbe(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSyncString(env, TSBackendPeerProbe,
        "Peer probe returned a null status",
        "Failed to create peer probe status");
}

napi_value BackendRestartWithTunImpl(napi_env env, napi_callback_info info, bool asynchronous)
{
    size_t argc = 5;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 5) {
        napi_throw_type_error(env, nullptr,
            "backendRestartWithTun requires state directory, device model, OS version, control server and TUN descriptor");
        return nullptr;
    }
    std::string directory;
    std::string model;
    std::string version;
    std::string control;
    if (!ReadBoundedUtf8Arg(env, args[0], kMaxPathBytes, true, directory,
            "VPN backend state directory must be a string", "Failed to read the VPN backend state directory") ||
        !ReadBoundedUtf8Arg(env, args[1], kMaxPathBytes, true, model,
            "VPN backend device model must be a string", "Failed to read the VPN backend device model") ||
        !ReadBoundedUtf8Arg(env, args[2], kMaxPathBytes, true, version,
            "VPN backend OS version must be a string", "Failed to read the VPN backend OS version") ||
        !ReadBoundedUtf8Arg(env, args[3], kMaxPathBytes, true, control,
            "VPN backend control server must be a string", "Failed to read the VPN backend control server")) {
        return nullptr;
    }
    int32_t fd = -1;
    if (napi_get_value_int32(env, args[4], &fd) != napi_ok) {
        napi_throw_type_error(env, nullptr, "VPN TUN descriptor must be an integer");
        return nullptr;
    }
    if (asynchronous) {
        // Own a duplicate before queueing: teardown may close/reuse the system fd
        // while the worker is waiting. RAII also covers queue/allocation failures.
        const int duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
        if (duplicate < 0) {
            napi_throw_error(env, nullptr, "Failed to retain VPN TUN descriptor");
            return nullptr;
        }
        OwnedTunDescriptor owned(duplicate);
        auto descriptor = std::make_shared<OwnedTunDescriptor>(std::move(owned));
        return CreateAsyncStringPromise(env,
            [directory = std::move(directory),
             model = std::move(model),
             version = std::move(version),
             control = std::move(control),
             descriptor]() {
                return TSBackendRestartWithTun(
                    const_cast<char*>(directory.c_str()),
                    const_cast<char*>(model.c_str()),
                    const_cast<char*>(version.c_str()),
                    const_cast<char*>(control.c_str()),
                    descriptor->fd);
            },
            "BackendRestartWithTunAsync");
    }
    char* message = TSBackendRestartWithTun(
        const_cast<char*>(directory.c_str()),
        const_cast<char*>(model.c_str()),
        const_cast<char*>(version.c_str()),
        const_cast<char*>(control.c_str()),
        fd);
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "VPN backend restart returned a null status");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer the VPN backend restart status");
        return nullptr;
    }
    return result;
}

napi_value BackendRestartWithTun(napi_env env, napi_callback_info info)
{
    return BackendRestartWithTunImpl(env, info, false);
}

napi_value BackendRestartWithTunAsync(napi_env env, napi_callback_info info)
{
    return BackendRestartWithTunImpl(env, info, true);
}

napi_value BackendStatusAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendStatus, "BackendStatusAsync");
}

napi_value ControlProbe(napi_env env, napi_callback_info info)
{
    (void)info;
    return CallSyncString(env, TSControlProbe,
        "Tailscale control probe returned a null string",
        "Failed to convert the Tailscale control probe status");
}

napi_value TunFdProbe(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "tunFdProbe requires one file descriptor");
        return nullptr;
    }
    int32_t fd = -1;
    if (napi_get_value_int32(env, args[0], &fd) != napi_ok) {
        napi_throw_type_error(env, nullptr, "tunFdProbe file descriptor must be an integer");
        return nullptr;
    }
    char* message = TSTunFDProbe(fd);
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "TUN descriptor probe returned a null string");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to convert the TUN descriptor probe status");
        return nullptr;
    }
    return result;
}
} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"createExclusiveFile", nullptr, GuardCallback<CreateExclusiveFile>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPathDiagnosticAsync", nullptr, GuardCallback<BackendPathDiagnosticAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hello", nullptr, GuardCallback<Hello>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeEngine", nullptr, GuardCallback<ProbeEngine>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeEngineAsync", nullptr, GuardCallback<ProbeEngineAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStart", nullptr, GuardCallback<BackendStart>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStop", nullptr, GuardCallback<BackendStop>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendLogout", nullptr, GuardCallback<BackendLogout>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStatus", nullptr, GuardCallback<BackendStatus>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendSnapshot", nullptr, GuardCallback<BackendSnapshotAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeerSnapshot", nullptr, GuardCallback<BackendPeerSnapshotAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendLocalSendRefreshAsync", nullptr, GuardCallback<BackendLocalSendRefreshAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildropIncomingSnapshot", nullptr, GuardCallback<BackendTaildropIncomingSnapshotAsync>,
            nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStopAsync", nullptr, GuardCallback<BackendStopAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendLogoutAsync", nullptr, GuardCallback<BackendLogoutAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendAuthURLAsync", nullptr, GuardCallback<BackendAuthURLAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendLoginWithAuthKeyAsync", nullptr, GuardCallback<BackendLoginWithAuthKeyAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendVpnConfigAsync", nullptr, GuardCallback<BackendVpnConfigAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendDnsConfigAsync", nullptr, GuardCallback<BackendDnsConfigAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendDnsRuntimeAsync", nullptr, GuardCallback<BackendDnsRuntimeAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendAuthURL", nullptr, GuardCallback<BackendAuthURL>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendVpnConfig", nullptr, GuardCallback<BackendVpnConfig>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendExitNodes", nullptr, GuardCallback<BackendExitNodes>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeers", nullptr, GuardCallback<BackendPeers>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendAccount", nullptr, GuardCallback<BackendAccount>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tailscaleVersion", nullptr, GuardCallback<TailscaleVersion>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendNetworkSettings", nullptr, GuardCallback<BackendNetworkSettings>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendSetNetworkSetting", nullptr, GuardCallback<BackendSetNetworkSetting>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendSetNetworkSettingAsync", nullptr, GuardCallback<BackendSetNetworkSettingAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendSetExitNode", nullptr, GuardCallback<BackendSetExitNode>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendSetExitNodeAsync", nullptr, GuardCallback<BackendSetExitNodeAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeerProbe", nullptr, GuardCallback<BackendPeerProbe>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeerProbeAsync", nullptr, GuardCallback<BackendPeerProbeAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendNetworkChangedAsync", nullptr, GuardCallback<BackendNetworkChangedAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendPeerConnectivityAsync", nullptr, GuardCallback<BackendPeerConnectivityAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendSunshineProbeAsync", nullptr, GuardCallback<BackendSunshineProbeAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendMediaServiceProbeAsync", nullptr, GuardCallback<BackendMediaServiceProbeAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"mediaProbeSelfTestAsync", nullptr, GuardCallback<BackendMediaProbeSelfTestAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildropSendAsync", nullptr, GuardCallback<BackendTaildropSendAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildropCancelAsync", nullptr, GuardCallback<BackendTaildropCancelAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildropReceiveAsync", nullptr, GuardCallback<BackendTaildropReceiveAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildriveListAsync", nullptr, GuardCallback<BackendTaildriveListAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildriveStatAsync", nullptr, GuardCallback<BackendTaildriveStatAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildriveMutateAsync", nullptr, GuardCallback<BackendTaildriveMutateAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildriveDownloadAsync", nullptr, GuardCallback<BackendTaildriveDownloadAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildriveManualDownloadAsync", nullptr, GuardCallback<BackendTaildriveManualDownloadAsync>,
            nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendTaildriveUploadAsync", nullptr, GuardCallback<BackendTaildriveUploadAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildriveTransferSnapshotAsync", nullptr, GuardCallback<BackendTaildriveTransferSnapshotAsync>,
            nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendTaildriveCancelAsync", nullptr, GuardCallback<BackendTaildriveCancelAsync>, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendRestartWithTun", nullptr, GuardCallback<BackendRestartWithTun>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendRestartWithTunAsync", nullptr, GuardCallback<BackendRestartWithTunAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStatusAsync", nullptr, GuardCallback<BackendStatusAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"controlProbe", nullptr, GuardCallback<ControlProbe>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tunFdProbe", nullptr, GuardCallback<TunFdProbe>, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_status status = napi_define_properties(
        env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to register the Tailscale OHOS native exports");
    }
    return exports;
}
EXTERN_C_END

static napi_module module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "tailscale_ohos",
    .nm_priv = nullptr,
    .reserved = {nullptr, nullptr, nullptr, nullptr}
};

extern "C" __attribute__((constructor)) void RegisterTailscaleOhosModule()
{
    napi_module_register(&module);
}
