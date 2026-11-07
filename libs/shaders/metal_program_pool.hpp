#pragma once
#import <MetalKit/MetalKit.h>

#include "shaders/program_pool.hpp"

#include "drape/pointers.hpp"

#include <map>
#include <string>

namespace gpu
{
enum class SystemProgram
{
  ClearColor = 0,
  ClearDepth,
  ClearColorAndDepth,

  SystemProgramsCount
};

namespace metal
{
/// Where to load the compiled shader library (shaders_metal.metallib) from, instead of the main
/// bundle. For an engine embedded in a framework, which has no say over the app's bundle.
/// Call before the first drawing engine is created. An empty path restores the default.
void SetShaderLibraryPath(std::string const & path);

class MetalProgramPool : public ProgramPool
{
public:
  explicit MetalProgramPool(id<MTLDevice> device);
  ~MetalProgramPool() override;

  drape_ptr<dp::GpuProgram> Get(Program program) override;
  drape_ptr<dp::GpuProgram> GetSystemProgram(SystemProgram program);

private:
  drape_ptr<dp::GpuProgram> Get(std::string_view programName, std::string const & vertexShaderName,
                                std::string const & fragmentShaderName, std::map<uint8_t, uint8_t> const & layout);

  id<MTLFunction> GetFunction(std::string const & name);
  id<MTLDevice> m_device;
  id<MTLLibrary> m_library;
  std::map<std::string, id<MTLFunction>> m_functions;
};
}  // namespace metal
}  // namespace gpu
