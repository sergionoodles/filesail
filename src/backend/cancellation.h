#pragma once

#include <atomic>
#include <memory>

using CancellationToken = std::shared_ptr<std::atomic_bool>;

inline bool cancellationRequested(const CancellationToken &token)
{
    return token && token->load(std::memory_order_relaxed);
}
