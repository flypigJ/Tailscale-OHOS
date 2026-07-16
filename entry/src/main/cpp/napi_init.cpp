#include "napi/native_api.h"
#include "hilog/log.h"
#include "libtailscale_go.h"
#include <string>
#include <vector>

namespace {
using AsyncStringFunction = char* (*)();

struct AsyncStringWork {
    napi_env env;
    napi_async_work work;
    napi_deferred deferred;
    AsyncStringFunction function;
    std::string result;
    bool succeeded;
};

enum class AsyncInputOperation {
    SetExitNode,
    SetNetworkSetting
};

struct AsyncInputWork {
    napi_async_work work;
    napi_deferred deferred;
    AsyncInputOperation operation;
    std::string input;
    bool enabled;
    std::string result;
    bool succeeded;
};

void ExecuteAsyncString(napi_env env, void* data)
{
    (void)env;
    auto* work = static_cast<AsyncStringWork*>(data);
    char* message = work->function();
    if (message == nullptr) {
        work->succeeded = false;
        return;
    }
    work->result.assign(message);
    TSFreeString(message);
    work->succeeded = true;
}

void CompleteAsyncString(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<AsyncStringWork*>(data);
    napi_value value = nullptr;
    if (status == napi_ok && work->succeeded &&
        napi_create_string_utf8(env, work->result.c_str(), NAPI_AUTO_LENGTH, &value) == napi_ok) {
        napi_resolve_deferred(env, work->deferred, value);
    } else {
        napi_value message = nullptr;
        napi_value error = nullptr;
        napi_create_string_utf8(env, "Native backend operation failed", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, work->deferred, error);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value CreateAsyncStringPromise(
    napi_env env, AsyncStringFunction function, const char* resourceName)
{
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create native backend promise");
        return nullptr;
    }
    auto* work = new AsyncStringWork{env, nullptr, deferred, function, "", false};
    napi_value resource = nullptr;
    if (napi_create_string_utf8(env, resourceName, NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, ExecuteAsyncString, CompleteAsyncString, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
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
    char* message = work->operation == AsyncInputOperation::SetExitNode ?
        TSBackendSetExitNode(const_cast<char*>(work->input.c_str())) :
        TSBackendSetNetworkSetting(const_cast<char*>(work->input.c_str()), work->enabled ? 1 : 0);
    if (message == nullptr) {
        work->succeeded = false;
        return;
    }
    work->result.assign(message);
    TSFreeString(message);
    work->succeeded = true;
}

void CompleteAsyncInput(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<AsyncInputWork*>(data);
    napi_value value = nullptr;
    if (status == napi_ok && work->succeeded &&
        napi_create_string_utf8(env, work->result.c_str(), NAPI_AUTO_LENGTH, &value) == napi_ok) {
        napi_resolve_deferred(env, work->deferred, value);
    } else {
        napi_value message = nullptr;
        napi_value error = nullptr;
        napi_create_string_utf8(env, "Native backend update failed", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, work->deferred, error);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value CreateAsyncInputPromise(
    napi_env env, AsyncInputOperation operation, const std::string& input, bool enabled, const char* resourceName)
{
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create native backend update promise");
        return nullptr;
    }
    auto* work = new AsyncInputWork{nullptr, deferred, operation, input, enabled, "", false};
    napi_value resource = nullptr;
    if (napi_create_string_utf8(env, resourceName, NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, ExecuteAsyncInput, CompleteAsyncInput, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
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
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Exit-node selection must be a string");
        return nullptr;
    }
    std::vector<char> selection(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], selection.data(), selection.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the exit-node selection");
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::SetExitNode, selection.data(), false, "TailscaleBackendSetExitNode");
}

napi_value BackendSetNetworkSettingAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
        napi_throw_type_error(env, nullptr, "backendSetNetworkSettingAsync requires a key and boolean value");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Network setting key must be a string");
        return nullptr;
    }
    std::vector<char> key(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], key.data(), key.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the network setting key");
        return nullptr;
    }
    bool enabled = false;
    if (napi_get_value_bool(env, args[1], &enabled) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Network setting value must be a boolean");
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::SetNetworkSetting, key.data(), enabled, "TailscaleBackendSetNetworkSetting");
}

napi_value BackendSnapshotAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendSnapshot, "TailscaleBackendSnapshot");
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

napi_value BackendVpnConfigAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendVPNConfig, "TailscaleBackendVpnConfig");
}

napi_value BackendMagicDNSProbeURLAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendMagicDNSProbeURL, "TailscaleBackendMagicDNSProbeURL");
}

napi_value ProbeEngineAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSProbeEngine, "TailscaleEngineProbe");
}

napi_value BackendPeerProbeAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendPeerProbe, "TailscaleBackendPeerProbe");
}

napi_value BackendArmMagicDNSProbeAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendArmMagicDNSProbe, "TailscaleBackendArmMagicDNSProbe");
}

napi_value Hello(napi_env env, napi_callback_info info)
{
    (void)info;
    OH_LOG_INFO(LOG_APP, "C++ N-API bridge loaded; calling Go runtime");
    char* message = TSHello();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Go bridge returned a null status string");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to convert the Go status to an ArkTS string");
        return nullptr;
    }
    return result;
}

napi_value ProbeEngine(napi_env env, napi_callback_info info)
{
    (void)info;
    OH_LOG_INFO(LOG_APP, "Initializing Tailscale userspace engine probe");
    char* message = TSProbeEngine();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale engine probe returned a null status string");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to convert the Tailscale engine status to an ArkTS string");
        return nullptr;
    }
    return result;
}

napi_value BackendStart(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
        napi_throw_type_error(env, nullptr, "backendStart requires state directory and device model");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "backendStart state directory must be a string");
        return nullptr;
    }
    std::vector<char> stateDir(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], stateDir.data(), stateDir.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the backend state directory");
        return nullptr;
    }
    size_t modelLength = 0;
    if (napi_get_value_string_utf8(env, args[1], nullptr, 0, &modelLength) != napi_ok) {
        napi_throw_type_error(env, nullptr, "backendStart device model must be a string");
        return nullptr;
    }
    std::vector<char> deviceModel(modelLength + 1, '\0');
    if (napi_get_value_string_utf8(env, args[1], deviceModel.data(), deviceModel.size(), &modelLength) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the backend device model");
        return nullptr;
    }
    OH_LOG_INFO(LOG_APP, "Starting the persistent Tailscale LocalBackend");
    char* message = TSBackendStart(stateDir.data(), deviceModel.data());
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
    char* message = TSBackendStop();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Backend stop returned a null status");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create backend stop status");
        return nullptr;
    }
    return result;
}

napi_value BackendLogout(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendLogout();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Backend logout returned a null status");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create backend logout status");
        return nullptr;
    }
    return result;
}

napi_value BackendStatus(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendStatus();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale backend status returned a null string");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to convert the Tailscale backend status");
        return nullptr;
    }
    return result;
}

napi_value BackendAuthURL(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendAuthURL();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale login URL is unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer the Tailscale login URL");
        return nullptr;
    }
    return result;
}

napi_value BackendVpnConfig(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendVPNConfig();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale VPN config is unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer the Tailscale VPN config");
        return nullptr;
    }
    return result;
}

napi_value BackendExitNodes(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendExitNodes();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Exit-node choices are unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer exit-node choices");
        return nullptr;
    }
    return result;
}

napi_value BackendPeers(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendPeers();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Peer summaries are unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer peer summaries");
        return nullptr;
    }
    return result;
}

napi_value BackendAccount(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendAccount();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Account summary is unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer the account summary");
        return nullptr;
    }
    return result;
}

napi_value TailscaleVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSTailscaleVersion();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale version is unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer the Tailscale version");
        return nullptr;
    }
    return result;
}

napi_value BackendNetworkSettings(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendNetworkSettings();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Network settings are unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer network settings");
        return nullptr;
    }
    return result;
}

napi_value BackendSetNetworkSetting(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
        napi_throw_type_error(env, nullptr, "backendSetNetworkSetting requires a key and boolean value");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Network setting key must be a string");
        return nullptr;
    }
    std::vector<char> key(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], key.data(), key.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the network setting key");
        return nullptr;
    }
    bool enabled = false;
    if (napi_get_value_bool(env, args[1], &enabled) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Network setting value must be a boolean");
        return nullptr;
    }
    char* message = TSBackendSetNetworkSetting(key.data(), enabled ? 1 : 0);
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
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Exit-node selection must be a string");
        return nullptr;
    }
    std::vector<char> selection(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], selection.data(), selection.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the exit-node selection");
        return nullptr;
    }
    char* message = TSBackendSetExitNode(selection.data());
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
    char* message = TSBackendPeerProbe();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Peer probe returned a null status");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create peer probe status");
        return nullptr;
    }
    return result;
}

napi_value BackendMagicDNSProbeURL(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendMagicDNSProbeURL();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "MagicDNS probe target is unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer the MagicDNS probe target");
        return nullptr;
    }
    return result;
}

napi_value BackendArmMagicDNSProbe(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendArmMagicDNSProbe();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "MagicDNS probe arming returned a null status");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create MagicDNS arming status");
        return nullptr;
    }
    return result;
}

napi_value BackendRestartWithTun(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 3) {
        napi_throw_type_error(env, nullptr, "backendRestartWithTun requires state directory, device model and TUN descriptor");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "VPN backend state directory must be a string");
        return nullptr;
    }
    std::vector<char> stateDir(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], stateDir.data(), stateDir.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the VPN backend state directory");
        return nullptr;
    }
    size_t modelLength = 0;
    if (napi_get_value_string_utf8(env, args[1], nullptr, 0, &modelLength) != napi_ok) {
        napi_throw_type_error(env, nullptr, "VPN backend device model must be a string");
        return nullptr;
    }
    std::vector<char> deviceModel(modelLength + 1, '\0');
    if (napi_get_value_string_utf8(env, args[1], deviceModel.data(), deviceModel.size(), &modelLength) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the VPN backend device model");
        return nullptr;
    }
    int32_t fd = -1;
    if (napi_get_value_int32(env, args[2], &fd) != napi_ok) {
        napi_throw_type_error(env, nullptr, "VPN TUN descriptor must be an integer");
        return nullptr;
    }
    char* message = TSBackendRestartWithTun(stateDir.data(), deviceModel.data(), fd);
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

napi_value ControlProbe(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSControlProbe();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale control probe returned a null string");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to convert the Tailscale control probe status");
        return nullptr;
    }
    return result;
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
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"hello", nullptr, Hello, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeEngine", nullptr, ProbeEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeEngineAsync", nullptr, ProbeEngineAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStart", nullptr, BackendStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStop", nullptr, BackendStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendLogout", nullptr, BackendLogout, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStatus", nullptr, BackendStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendSnapshot", nullptr, BackendSnapshotAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStopAsync", nullptr, BackendStopAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendLogoutAsync", nullptr, BackendLogoutAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendAuthURLAsync", nullptr, BackendAuthURLAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendVpnConfigAsync", nullptr, BackendVpnConfigAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendAuthURL", nullptr, BackendAuthURL, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendVpnConfig", nullptr, BackendVpnConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendExitNodes", nullptr, BackendExitNodes, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeers", nullptr, BackendPeers, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendAccount", nullptr, BackendAccount, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tailscaleVersion", nullptr, TailscaleVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendNetworkSettings", nullptr, BackendNetworkSettings, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendSetNetworkSetting", nullptr, BackendSetNetworkSetting, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendSetNetworkSettingAsync", nullptr, BackendSetNetworkSettingAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendSetExitNode", nullptr, BackendSetExitNode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendSetExitNodeAsync", nullptr, BackendSetExitNodeAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeerProbe", nullptr, BackendPeerProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeerProbeAsync", nullptr, BackendPeerProbeAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendMagicDNSProbeURL", nullptr, BackendMagicDNSProbeURL, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendMagicDNSProbeURLAsync", nullptr, BackendMagicDNSProbeURLAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendArmMagicDNSProbe", nullptr, BackendArmMagicDNSProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendArmMagicDNSProbeAsync", nullptr, BackendArmMagicDNSProbeAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendRestartWithTun", nullptr, BackendRestartWithTun, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"controlProbe", nullptr, ControlProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tunFdProbe", nullptr, TunFdProbe, nullptr, nullptr, nullptr, napi_default, nullptr}
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
    .reserved = {0}
};

extern "C" __attribute__((constructor)) void RegisterTailscaleOhosModule()
{
    napi_module_register(&module);
}
