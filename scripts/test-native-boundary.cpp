#include "../entry/src/main/cpp/native_boundary.h"
#include <cassert>
#include <cstring>
#include <memory>
#include <new>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
int freed = 0;
void Free(char* value) { ++freed; delete[] value; }
char* Message() { return new char[3]{'o', 'k', '\0'}; }
struct FailingDestination {
    void assign(const char*) { throw std::bad_alloc(); }
};

void TestScrubAndEmbeddedNull()
{
    mesharc::ScrubMemory(nullptr, 16);
    char secretBuf[16] = "tskey-auth-1234";
    mesharc::ScrubMemory(secretBuf, sizeof(secretBuf));
    for (char c : secretBuf) {
        assert(c == 0);
    }

    std::string secretStr("tskey-auth-secret-token-value-longer-than-sso-buffer-1234567890");
    const char* rawPtr = secretStr.data();
    const size_t rawLen = secretStr.size();
    mesharc::ScrubString(secretStr);
    assert(secretStr.empty());
    (void)rawPtr;
    (void)rawLen;

    std::string shortSecret("tskey-short");
    mesharc::ScrubString(shortSecret);
    assert(shortSecret.empty());

    std::vector<char> vec{'s', 'e', 'c', 'r', 'e', 't', '\0'};
    char* vecPtr = vec.data();
    const size_t vecSize = vec.size();
    {
        mesharc::ScopedScrubBuffer guard(vec);
        assert(vecPtr[0] == 's');
    }
    for (size_t i = 0; i < vecSize; ++i) {
        assert(vecPtr[i] == 0);
    }

    assert(!mesharc::HasEmbeddedNull(nullptr, 0));
    assert(!mesharc::HasEmbeddedNull("abc", 0));
    assert(!mesharc::HasEmbeddedNull("abcdef", 6));
    const char embedded[] = {'a', 'b', '\0', 'c', 'd'};
    assert(mesharc::HasEmbeddedNull(embedded, sizeof(embedded)));
    assert(!mesharc::HasEmbeddedNull(embedded, 2));
}

void TestBoundedWorkQueue()
{
    // Transfer lane simulation (maxInFlight = 2).
    mesharc::BoundedWorkQueue<int> transferLane(2);
    assert(transferLane.MaxInFlight() == 2);
    assert(transferLane.InFlight() == 0 && transferLane.Pending() == 0);

    assert(transferLane.TryAcquireOrEnqueue(101));
    assert(transferLane.InFlight() == 1 && transferLane.Pending() == 0);
    assert(transferLane.TryAcquireOrEnqueue(102));
    assert(transferLane.InFlight() == 2 && transferLane.Pending() == 0);

    // 3rd and 4th slow transfers queue in FIFO order without exceeding 2 in-flight workers.
    assert(!transferLane.TryAcquireOrEnqueue(103));
    assert(!transferLane.TryAcquireOrEnqueue(104));
    assert(transferLane.InFlight() == 2 && transferLane.Pending() == 2);

    int next = 0;
    assert(transferLane.ReleaseAndTakeNext(next));
    assert(next == 103 && transferLane.InFlight() == 2 && transferLane.Pending() == 1);

    assert(transferLane.ReleaseAndTakeNext(next));
    assert(next == 104 && transferLane.InFlight() == 2 && transferLane.Pending() == 0);

    assert(!transferLane.ReleaseAndTakeNext(next));
    assert(transferLane.InFlight() == 1 && transferLane.Pending() == 0);

    assert(!transferLane.ReleaseAndTakeNext(next));
    assert(transferLane.InFlight() == 0 && transferLane.Pending() == 0);

    // Immediate queue failure rolls back slot reservation cleanly.
    assert(transferLane.TryAcquireOrEnqueue(201));
    assert(transferLane.InFlight() == 1);
    transferLane.ReleaseOnImmediateQueueFailure();
    assert(transferLane.InFlight() == 0);

    // Probe lane simulation (maxInFlight = 1, plus move-only task type).
    mesharc::BoundedWorkQueue<std::unique_ptr<int>> probeLane(0); // 0 clamps to 1
    assert(probeLane.MaxInFlight() == 1);
    auto first = std::make_unique<int>(1);
    assert(probeLane.TryAcquireOrEnqueue(std::move(first)));
    assert(first != nullptr && *first == 1); // Untouched when slot acquired immediately.
    assert(!probeLane.TryAcquireOrEnqueue(std::make_unique<int>(2)));
    assert(probeLane.InFlight() == 1 && probeLane.Pending() == 1);

    std::unique_ptr<int> nextProbe;
    assert(probeLane.ReleaseAndTakeNext(nextProbe));
    assert(nextProbe != nullptr && *nextProbe == 2);
    assert(!probeLane.ReleaseAndTakeNext(nextProbe));
    assert(probeLane.InFlight() == 0 && probeLane.Pending() == 0);
}
}

int main()
{
    std::string result;
    assert(mesharc::CopyNativeString(Message, result, Free));
    assert(result == "ok" && freed == 1);
    FailingDestination failing;
    assert(!mesharc::CopyNativeString(Message, failing, Free));
    assert(freed == 2); // Result allocation failure still frees the Go buffer.
    assert(!mesharc::CopyNativeString([]() -> char* { return nullptr; }, result, Free));
    assert(freed == 2);
    assert(!mesharc::CopyNativeString([]() -> char* { throw std::runtime_error("private"); }, result, Free));
    int failures = 0;
    assert(mesharc::GuardNativeCall([] { return 7; }, [&] { ++failures; return -1; }) == 7);
    assert(mesharc::GuardNativeCall([]() -> int { throw std::bad_alloc(); }, [&] { ++failures; return -1; }) == -1);
    assert(mesharc::GuardNativeCall([]() -> int { throw 1; }, [&] { ++failures; return -1; }) == -1);
    assert(failures == 2);

    TestScrubAndEmbeddedNull();
    TestBoundedWorkQueue();
    return 0;
}
