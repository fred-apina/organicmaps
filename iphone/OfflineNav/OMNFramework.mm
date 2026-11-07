#include "OMNInternal.hpp"

namespace
{
Framework * g_framework = nullptr;
}  // namespace

Framework & OMNFramework()
{
  if (g_framework == nullptr)
    g_framework = new Framework();
  return *g_framework;
}
