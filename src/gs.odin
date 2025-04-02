package main
import vma "../shared/vma"
import "base:runtime"
import "core:fmt"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

window: ^sdl.Window
screenWidth: i32 = 1280
screenHeight: i32 = 720
dt: f64

vkVmaProcs: vma.Vulkan_Functions
vkInstance: vk.Instance
vkDebugMessenger: vk.DebugUtilsMessengerEXT
vkGpu: vk.PhysicalDevice
vkDevice: vk.Device
vkQueue: vk.Queue
vkCommandPool: vk.CommandPool
vkAppAlocator: vma.Allocator
vkSemaphores: struct {
	submit:  vk.Semaphore,
	acquire: vk.Semaphore,
} = {}

vkSurfaceFormat: vk.SurfaceFormatKHR
vkQueueIdx: u32 = max(u32)
vkSurface: vk.SurfaceKHR
TOTAL_SWAPCHAIN_IMAGES :: 3
vkScImgCount: u32 = max(u32)

vkScImages: [TOTAL_SWAPCHAIN_IMAGES]vk.Image
vkScImageViews: [TOTAL_SWAPCHAIN_IMAGES]vk.ImageView
vkFrameBuffers: [TOTAL_SWAPCHAIN_IMAGES]vk.Framebuffer

#assert(
	len(vkScImages) == len(vkScImageViews) &&
	len(vkScImageViews) == len(vkFrameBuffers) &&
	len(vkFrameBuffers) == TOTAL_SWAPCHAIN_IMAGES,
)
vkSwapchain: vk.SwapchainKHR
vkRenderPass: vk.RenderPass

vk_debug_callback :: proc "std" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = runtime.default_context()
	fmt.printfln("Validation Error : %v", pCallbackData.pMessage)
	return false
}
