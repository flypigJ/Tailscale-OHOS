#pragma once

#include <cstddef>
#include <deque>
#include <memory>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

namespace mesharc {
// C++ exceptions must not unwind through the C callbacks owned by the VM.
// Failure handlers must themselves be allocation-free and non-throwing.
template <typename Call, typename Failure>
auto GuardNativeCall(Call&& call, Failure&& failure) noexcept -> decltype(call())
{
    try {
        return call();
    } catch (...) {
        return failure();
    }
}

// Keep the Go-owned buffer alive only while copying, including allocation failure.
template <typename Producer, typename Destination, typename Free>
bool CopyNativeString(Producer&& producer, Destination& destination, Free freeString) noexcept
{
    return GuardNativeCall([&]() {
        std::unique_ptr<char, Free> message(producer(), freeString);
        if (!message) {
            return false;
        }
        destination.assign(message.get());
        return true;
    }, []() noexcept { return false; });
}

inline void ScrubMemory(char* data, size_t length) noexcept
{
    if (data == nullptr || length == 0) {
        return;
    }
    volatile char* p = data;
    for (size_t i = 0; i < length; ++i) {
        p[i] = 0;
    }
}

inline void ScrubString(std::string& value) noexcept
{
    if (!value.empty()) {
        ScrubMemory(&value[0], value.size());
    }
    const size_t cap = value.capacity();
    if (cap > 0) {
        GuardNativeCall([&]() {
            value.resize(cap, '\0');
            ScrubMemory(&value[0], cap);
        }, []() noexcept {});
    }
    value.clear();
}

class ScopedScrubBuffer {
public:
    explicit ScopedScrubBuffer(std::vector<char>& buffer) noexcept : buffer_(buffer) {}
    ScopedScrubBuffer(const ScopedScrubBuffer&) = delete;
    ScopedScrubBuffer& operator=(const ScopedScrubBuffer&) = delete;
    ~ScopedScrubBuffer() noexcept
    {
        if (!buffer_.empty()) {
            ScrubMemory(buffer_.data(), buffer_.size());
        }
    }

private:
    std::vector<char>& buffer_;
};

inline bool HasEmbeddedNull(const char* data, size_t length) noexcept
{
    if (data == nullptr || length == 0) {
        return false;
    }
    return std::char_traits<char>::find(data, length, '\0') != nullptr;
}

// Bounds concurrent slow operations so libuv's 4-worker pool always retains
// capacity for fast status, snapshot, DNS, and teardown work.
template <typename Task>
class BoundedWorkQueue {
public:
    explicit BoundedWorkQueue(size_t maxInFlight) noexcept
        : maxInFlight_(maxInFlight == 0 ? 1 : maxInFlight), inFlight_(0) {}

    BoundedWorkQueue(const BoundedWorkQueue&) = delete;
    BoundedWorkQueue& operator=(const BoundedWorkQueue&) = delete;

    bool TryAcquireOrEnqueue(Task&& task)
    {
        if (inFlight_ < maxInFlight_) {
            ++inFlight_;
            return true;
        }
        pending_.push_back(std::move(task));
        return false;
    }

    bool ReleaseAndTakeNext(Task& nextOut) noexcept(std::is_nothrow_move_assignable<Task>::value)
    {
        if (!pending_.empty()) {
            nextOut = std::move(pending_.front());
            pending_.pop_front();
            return true;
        }
        if (inFlight_ > 0) {
            --inFlight_;
        }
        return false;
    }

    void ReleaseOnImmediateQueueFailure() noexcept
    {
        if (inFlight_ > 0) {
            --inFlight_;
        }
    }

    size_t InFlight() const noexcept { return inFlight_; }
    size_t Pending() const noexcept { return pending_.size(); }
    size_t MaxInFlight() const noexcept { return maxInFlight_; }

private:
    size_t maxInFlight_;
    size_t inFlight_;
    std::deque<Task> pending_;
};
} // namespace mesharc
