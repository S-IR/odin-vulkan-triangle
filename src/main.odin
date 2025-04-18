package main

// import vma "../shared/vma"
import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:path/filepath"
import "core:prof/spall"
import "core:sync"
import "core:time"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"
APP_NAME :: "Learn Vulkan"

sdl_ensure :: #force_inline proc(cond: bool, message: string = "") {
	if cond do return
	ensure(cond, fmt.tprintf("%s:%s\n", message, sdl.GetError()))
}

vk_ensure :: #force_inline proc(vRes: vk.Result, extraMsg := "") {
	if vRes == .SUCCESS do return
	msg: string = ---
	if len(extraMsg) == 0 {
		msg = fmt.tprintfln("%v", extraMsg, vRes)
	} else {
		msg = fmt.tprintfln("%s : %v", extraMsg, vRes)
	}
	ensure(false, msg)
}

float2 :: [2]f32
float3 :: [3]f32
float4 :: [4]f32
ENABLE_SPALL :: false

when ODIN_DEBUG && ENABLE_SPALL {
	spall_ctx: spall.Context
	@(thread_local)
	spall_buffer: spall.Buffer


	@(instrumentation_enter)
	spall_enter :: proc "contextless" (
		proc_address, call_site_return_address: rawptr,
		loc: runtime.Source_Code_Location,
	) {
		spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
	}

	@(instrumentation_exit)
	spall_exit :: proc "contextless" (
		proc_address, call_site_return_address: rawptr,
		loc: runtime.Source_Code_Location,
	) {
		spall._buffer_end(&spall_ctx, &spall_buffer)
	}

}
CHOSEN_GPU_BACKEND :: sdl.GPUShaderFormatFlag.SPIRV
main :: proc() {
	// sdl.SetLogPriorities(.VERBOSE)
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}

		when ENABLE_SPALL {
			spall_ctx = spall.context_create("spall-trace.spall")
			defer spall.context_destroy(&spall_ctx)

			buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
			defer delete(buffer_backing)

			spall_buffer = spall.buffer_create(buffer_backing, u32(sync.current_thread_id()))
			defer spall.buffer_destroy(&spall_ctx, &spall_buffer)
		}

	}
	sdl_ensure(sdl.Init({.VIDEO}))


	window = sdl.CreateWindow(APP_NAME, i32(screenWidth), i32(screenHeight), {.RESIZABLE, .VULKAN})
	sdl_ensure(window != nil)
	defer sdl.DestroyWindow(window)


	vk_init()
	defer vk_destroy()

	vk_triangle_init()
	defer vk_triangle_destroy()


	free_all(context.temp_allocator)

	e: sdl.Event
	quit := false
	for !quit {

		defer free_all(context.temp_allocator)
		// defer {
		// 	frameEnd := time.now()
		// 	frameDuration := time.diff(frameEnd, lastFrameTime)


		// 	if frameDuration < frameTime {
		// 		sleepTime := frameTime - frameDuration
		// 		time.sleep(sleepTime)
		// 	}

		// 	dt = time.duration_seconds(time.since(lastFrameTime))
		// 	lastFrameTime = time.now()
		// }

		for sdl.PollEvent(&e) {


			#partial switch e.type {
			case .QUIT:
				quit = true
				break
			case .KEY_DOWN:
				switch e.key.key {
				case sdl.K_F11:
					flags := sdl.GetWindowFlags(window)
					if .FULLSCREEN in flags {
						sdl.SetWindowFullscreen(window, false)
					} else {
						sdl.SetWindowFullscreen(window, true)
					}
				case sdl.K_ESCAPE:
					quit = true

				}

			case .WINDOW_RESIZED:
				screenWidth, screenHeight = e.window.data1, e.window.data2
			// case .MOUSE_MOTION:
			// Camera_process_mouse_movement(&camera, e.motion.xrel, e.motion.yrel)
			case:
				continue
			}
		}
		vk_render()

	}
}
vk_init :: proc() {
	sdl_ensure(sdl.Vulkan_LoadLibrary(nil), "Failed to load Vulkan library")
	vk.load_proc_addresses(rawptr(sdl.Vulkan_GetVkGetInstanceProcAddr()))

	extensions := [?]cstring {
		vk.KHR_SURFACE_EXTENSION_NAME,
		vk.EXT_DEBUG_UTILS_EXTENSION_NAME,
		vk.KHR_WIN32_SURFACE_EXTENSION_NAME,
	}


	layers := [?]cstring{"VK_LAYER_KHRONOS_validation"}
	vRes := vk.CreateInstance(
		&vk.InstanceCreateInfo {
			sType = .INSTANCE_CREATE_INFO,
			ppEnabledExtensionNames = raw_data(extensions[:]),
			enabledExtensionCount = len(extensions),
			enabledLayerCount = len(layers),
			ppEnabledLayerNames = raw_data(layers[:]),
			pApplicationInfo = &vk.ApplicationInfo {
				pApplicationName = APP_NAME,
				pEngineName = "Ponginne",
				sType = .APPLICATION_INFO,
				apiVersion = vk.MAKE_VERSION(1, 3, 2),
			},
		},
		nil,
		&vkInstance,
	)

	when ODIN_DEBUG {
		vk.CreateDebugUtilsMessengerEXT =
		auto_cast vk.GetInstanceProcAddr(vkInstance, "vkCreateDebugUtilsMessengerEXT")
		ensure(vk.CreateDebugUtilsMessengerEXT != nil)
		vk.CreateDebugUtilsMessengerEXT(
			vkInstance,
			&vk.DebugUtilsMessengerCreateInfoEXT {
				sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
				messageSeverity = {.ERROR, .WARNING},
				messageType = {.VALIDATION, .GENERAL, .PERFORMANCE},
				pfnUserCallback = vk_debug_callback,
			},
			nil,
			&vkDebugMessenger,
		)
	}
	vk_ensure(vRes)
	ensure(vkInstance != nil)
	vk.load_proc_addresses_instance(vkInstance)


	// Corrected surface declaration and usage
	ensure(
		sdl.Vulkan_CreateSurface(window, vkInstance, nil, &vkSurface),
		"could not create vulkan surface",
	)


	{
		gpuCount: u32 = 0
		vk_ensure(vk.EnumeratePhysicalDevices(vkInstance, &gpuCount, nil))
		physicalDevices := make([dynamic]vk.PhysicalDevice, gpuCount, context.temp_allocator)

		vk_ensure(vk.EnumeratePhysicalDevices(vkInstance, &gpuCount, raw_data(physicalDevices[:])))
		for i in 0 ..< gpuCount {
			gpu := physicalDevices[i]

			queueFamilyCount: u32 = 0
			vk.GetPhysicalDeviceQueueFamilyProperties(gpu, &queueFamilyCount, nil)
			queueFamilies := make(
				[]vk.QueueFamilyProperties,
				queueFamilyCount,
				context.temp_allocator,
			)

			vk.GetPhysicalDeviceQueueFamilyProperties(
				gpu,
				&queueFamilyCount,
				raw_data(queueFamilies[:]),
			)

			vkQueueIdx = max(u32)
			for j in 0 ..< queueFamilyCount {
				if queueFamilies[j].queueFlags >= {.GRAPHICS} {
					surfaceSupport: b32 = false
					vk_ensure(
						vk.GetPhysicalDeviceSurfaceSupportKHR(gpu, j, vkSurface, &surfaceSupport),
					)
					if !surfaceSupport do continue

					vkGpu = gpu
					vkQueueIdx = j
					break
				}
			}
			if vkQueueIdx == max(u32) do panic("could not find a suitable gpu for this application that can run graphics")
		}

	}
	ensure(vkGpu != {})

	{
		queuePriority := [?]f32{1.0}


		queue := [?]vk.DeviceQueueCreateInfo {
			{
				sType = .DEVICE_QUEUE_CREATE_INFO,
				queueFamilyIndex = vkQueueIdx,
				pQueuePriorities = raw_data(queuePriority[:]),
				queueCount = 1,
			},
		}

		// Use only the device-supported extension(s), typically VK_KHR_swapchain for rendering
		deviceExtensions := [?]cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}

		vk.CreateDevice(
			vkGpu,
			&vk.DeviceCreateInfo {
				sType = .DEVICE_CREATE_INFO,
				queueCreateInfoCount = len(queue),
				pQueueCreateInfos = raw_data(queue[:]),
				enabledExtensionCount = len(deviceExtensions),
				ppEnabledExtensionNames = raw_data(deviceExtensions[:]),
			},
			nil,
			&vkDevice,
		)
		ASSUMED_MIN_QUEUE_LEN :: 1
		#assert(len(queuePriority) >= ASSUMED_MIN_QUEUE_LEN)
		vk.GetDeviceQueue(vkDevice, vkQueueIdx, ASSUMED_MIN_QUEUE_LEN - 1, &vkQueue)
	}

	ensure(vkQueue != {})
	ensure(vkDevice != {})
	// {
	// 	vkVmaProcs = vma.create_vulkan_functions()
	// 	vRes = vma.create_allocator(
	// 		vma.Allocator_Create_Info {
	// 			flags = {.Buffer_Device_Address},
	// 			instance = vkInstance,
	// 			vulkan_api_version = vk.MAKE_VERSION(1, 3, 2),
	// 			physical_device = vkGpu,
	// 			device = vkDevice,
	// 			vulkan_functions = &vkVmaProcs,
	// 		},
	// 		&vkAppAlocator,
	// 	)
	// 	vk_ensure(vRes)
	// }
	// ensure(vkAppAlocator != {})

	{
		MAX_SURFACE_CAPS :: 64
		surfaceCaps := [MAX_SURFACE_CAPS]vk.SurfaceCapabilitiesKHR{}
		vk_ensure(
			vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vkGpu, vkSurface, raw_data(surfaceCaps[:])),
		)
		ensure(surfaceCaps[0] != {})

		// Force swapchain to have exactly 3 images if allowed.
		imgCount: u32 = 3
		ensure(
			imgCount < surfaceCaps[0].maxImageCount,
			fmt.tprintf(
				"too few image counts for swapchain, expected :%v",
				TOTAL_SWAPCHAIN_IMAGES,
			),
		)

		formatCount: u32 = max(u32)
		vRes = vk.GetPhysicalDeviceSurfaceFormatsKHR(vkGpu, vkSurface, &formatCount, nil)
		vk_ensure(vRes)
		ensure(formatCount != max(u32), "could not get physical device surface format")
		surfaceFormats := make([dynamic]vk.SurfaceFormatKHR, formatCount, context.temp_allocator)
		vRes = vk.GetPhysicalDeviceSurfaceFormatsKHR(
			vkGpu,
			vkSurface,
			&formatCount,
			raw_data(surfaceFormats[:]),
		)
		vk_ensure(vRes)

		for i in 0 ..< formatCount {
			currLoopFormat := surfaceFormats[i]
			if currLoopFormat.format == .B8G8R8A8_SRGB &&
			   currLoopFormat.colorSpace == .COLORSPACE_SRGB_NONLINEAR {
				vkSurfaceFormat = currLoopFormat
				break
			}
		}

		// Use the surface's current extent, or clamp to the window size if necessary.
		swapchainExtent: vk.Extent2D = surfaceCaps[0].currentExtent
		if swapchainExtent.width == 0 || swapchainExtent.height == 0 {
			swapchainExtent.width = u32(screenWidth)
			swapchainExtent.height = u32(screenHeight)
			if swapchainExtent.width < surfaceCaps[0].minImageExtent.width {
				swapchainExtent.width = surfaceCaps[0].minImageExtent.width
			}
			if swapchainExtent.height < surfaceCaps[0].minImageExtent.height {
				swapchainExtent.height = surfaceCaps[0].minImageExtent.height
			}
			if swapchainExtent.width > surfaceCaps[0].maxImageExtent.width {
				swapchainExtent.width = surfaceCaps[0].maxImageExtent.width
			}
			if swapchainExtent.height > surfaceCaps[0].maxImageExtent.height {
				swapchainExtent.height = surfaceCaps[0].maxImageExtent.height
			}
		}

		swapchainCreateInfo := vk.SwapchainCreateInfoKHR {
			sType            = .SWAPCHAIN_CREATE_INFO_KHR,
			surface          = vkSurface,
			minImageCount    = imgCount,
			imageFormat      = vkSurfaceFormat.format,
			imageColorSpace  = vkSurfaceFormat.colorSpace,
			imageExtent      = swapchainExtent,
			imageArrayLayers = 1,
			imageUsage       = {.COLOR_ATTACHMENT},
			preTransform     = surfaceCaps[0].currentTransform,
			compositeAlpha   = {.OPAQUE},
			presentMode      = .FIFO,
			clipped          = true,
		}

		allocCallbacks := vk.AllocationCallbacks{}
		vk_ensure(vk.CreateSwapchainKHR(vkDevice, &swapchainCreateInfo, nil, &vkSwapchain))
	}

	ensure(vkSurfaceFormat.format != .UNDEFINED, "chosen surface format is undefined!")

	{
		vRes = vk.GetSwapchainImagesKHR(vkDevice, vkSwapchain, &vkScImgCount, nil)
		vk_ensure(vRes)
		ensure(vkScImgCount <= u32(TOTAL_SWAPCHAIN_IMAGES))

		vRes = vk.GetSwapchainImagesKHR(
			vkDevice,
			vkSwapchain,
			&vkScImgCount,
			raw_data(vkScImages[:]),
		)
		vk_ensure(vRes)
	}
	ensure(vkScImages != {})


	{
		for i in 0 ..< len(vkScImageViews) {
			vRes = vk.CreateImageView(
				vkDevice,
				&vk.ImageViewCreateInfo {
					sType = .IMAGE_VIEW_CREATE_INFO,
					image = vkScImages[i],
					format = vkSurfaceFormat.format,
					viewType = .D2,
					subresourceRange = {aspectMask = {.COLOR}, layerCount = 1, levelCount = 1},
				},
				nil,
				&vkScImageViews[i],
			)
			vk_ensure(vRes)

		}
	}
	ensure(vkScImageViews != {})

	{
		vRes = vk.CreateCommandPool(
			vkDevice,
			&vk.CommandPoolCreateInfo {
				sType = .COMMAND_POOL_CREATE_INFO,
				queueFamilyIndex = vkQueueIdx,
			},
			nil,
			&vkCommandPool,
		)
		vk_ensure(vRes)

	}

	{
		semaInfo := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		vk_ensure(vk.CreateSemaphore(vkDevice, &semaInfo, nil, &vkSemaphores.acquire))
		vk_ensure(vk.CreateSemaphore(vkDevice, &semaInfo, nil, &vkSemaphores.submit))

	}
	ensure(vkSemaphores.acquire != {})
	ensure(vkSemaphores.submit != {})

	ensure(vkCommandPool != {})

	{
		attachmentDesc := vk.AttachmentDescription {
			loadOp        = .CLEAR,
			initialLayout = .UNDEFINED,
			finalLayout   = .PRESENT_SRC_KHR,
			storeOp       = .STORE,
			samples       = {._1},
			format        = vkSurfaceFormat.format,
		}

		colorAttachmentRef := vk.AttachmentReference {
			attachment = 0,
			layout     = .COLOR_ATTACHMENT_OPTIMAL,
		}
		attachments := [?]vk.AttachmentDescription{attachmentDesc}
		vRes = vk.CreateRenderPass(
			vkDevice,
			&vk.RenderPassCreateInfo {
				sType = .RENDER_PASS_CREATE_INFO,
				pAttachments = raw_data(attachments[:]),
				attachmentCount = len(attachments),
				subpassCount = 1,
				pSubpasses = &vk.SubpassDescription {
					colorAttachmentCount = 1,
					pColorAttachments = &colorAttachmentRef,
				},
			},
			nil,
			&vkRenderPass,
		)
		vk_ensure(vRes)

	}
	ensure(vkRenderPass != {})

	{
		frameBufferCreateInfo := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			width           = u32(screenWidth),
			height          = u32(screenHeight),
			renderPass      = vkRenderPass,
			layers          = 1,
			attachmentCount = 1,
		}

		for i in 0 ..< TOTAL_SWAPCHAIN_IMAGES {
			frameBufferCreateInfo.pAttachments = &vkScImageViews[i]
			vRes = vk.CreateFramebuffer(vkDevice, &frameBufferCreateInfo, nil, &vkFrameBuffers[i])
			vk_ensure(vRes)

		}
	}
	free_all(context.temp_allocator)
}
vk_destroy :: proc() {
	vk.DestroySemaphore(vkDevice, vkSemaphores.submit, nil)
	vk.DestroySemaphore(vkDevice, vkSemaphores.acquire, nil)
	for i in 0 ..< TOTAL_SWAPCHAIN_IMAGES {
		vk.DestroyImageView(vkDevice, vkScImageViews[i], nil)
		vk.DestroyFramebuffer(vkDevice, vkFrameBuffers[i], nil)
	}
	vk.DestroySwapchainKHR(vkDevice, vkSwapchain, nil)
	vk.DestroyRenderPass(vkDevice, vkRenderPass, nil)
	// vma.destroy_allocator(vkAppAlocator)
	vk.DestroyCommandPool(vkDevice, vkCommandPool, nil)
	vk.DestroySurfaceKHR(vkInstance, vkSurface, nil)
	vk.DestroyDevice(vkDevice, nil)
	when ODIN_DEBUG {
		vk.DestroyDebugUtilsMessengerEXT(vkInstance, vkDebugMessenger, nil)
	}
	vk.DestroyInstance(vkInstance, nil)

}
Triangle_r: struct {
	pipeline:       vk.Pipeline,
	pipelineLayout: vk.PipelineLayout,
} = {}

vk_triangle_init :: proc() {
	vRes: vk.Result

	{
		vRes = vk.CreatePipelineLayout(
			vkDevice,
			&vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO},
			nil,
			&Triangle_r.pipelineLayout,
		)
		vk_ensure(vRes)
	}

	ensure(Triangle_r.pipelineLayout != {})
	{

		vertexShader, fragmentShader: vk.ShaderModule
		shaderModuleInfo := vk.ShaderModuleCreateInfo {
			sType = .SHADER_MODULE_CREATE_INFO,
		}

		shaderModuleInfo.pCode = auto_cast raw_data(Available_Shader_Binaries[.TriangleVert])
		shaderModuleInfo.codeSize = len(Available_Shader_Binaries[.TriangleVert])
		ensure(shaderModuleInfo.pCode != nil)
		ensure(shaderModuleInfo.codeSize > 0)
		vk_ensure(vk.CreateShaderModule(vkDevice, &shaderModuleInfo, nil, &vertexShader))
		defer vk.DestroyShaderModule(vkDevice, vertexShader, nil)

		shaderModuleInfo.pCode = auto_cast raw_data(Available_Shader_Binaries[.TriangleFrag])
		shaderModuleInfo.codeSize = len(Available_Shader_Binaries[.TriangleFrag])
		ensure(shaderModuleInfo.pCode != nil)
		ensure(shaderModuleInfo.codeSize > 0)
		vk_ensure(vk.CreateShaderModule(vkDevice, &shaderModuleInfo, nil, &fragmentShader))
		defer vk.DestroyShaderModule(vkDevice, fragmentShader, nil)

		shaderStages := [?]vk.PipelineShaderStageCreateInfo {
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				pName = "main",
				stage = {.VERTEX},
				module = vertexShader,
			},
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				pName = "main",
				stage = {.FRAGMENT},
				module = fragmentShader,
			},
		}
		dynamicStates := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}

		pipeInfo := vk.GraphicsPipelineCreateInfo {
			sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
			pColorBlendState    = &vk.PipelineColorBlendStateCreateInfo {
				sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
				pAttachments = &vk.PipelineColorBlendAttachmentState {
					blendEnable = false,
					colorWriteMask = {.R, .G, .B, .A},
				},
				attachmentCount = 1,
			},
			pVertexInputState   = &vk.PipelineVertexInputStateCreateInfo {
				sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			},
			pStages             = raw_data(shaderStages[:]),
			stageCount          = len(shaderStages),
			pRasterizationState = &vk.PipelineRasterizationStateCreateInfo {
				sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
				frontFace = .CLOCKWISE,
				cullMode = {.BACK},
				polygonMode = .FILL,
				lineWidth = 1.0,
			},
			layout              = Triangle_r.pipelineLayout,
			renderPass          = vkRenderPass,
			pViewportState      = &vk.PipelineViewportStateCreateInfo {
				sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
				scissorCount = 1,
				viewportCount = 1,
				pScissors = &vk.Rect2D{},
				pViewports = &vk.Viewport{},
			},
			pDynamicState       = &vk.PipelineDynamicStateCreateInfo {
				pDynamicStates = raw_data(dynamicStates[:]),
				dynamicStateCount = len(dynamicStates),
				sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			},
			pMultisampleState   = &vk.PipelineMultisampleStateCreateInfo {
				sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
				rasterizationSamples = {._1},
			},
			pInputAssemblyState = &vk.PipelineInputAssemblyStateCreateInfo {
				sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
				topology = .TRIANGLE_LIST,
			},
		}
		vk.CreateGraphicsPipelines(vkDevice, 0, 1, &pipeInfo, nil, &Triangle_r.pipeline)
	}
	ensure(&Triangle_r.pipeline != {})
}
vk_triangle_destroy :: proc() {
	vk.DestroyPipelineLayout(vkDevice, Triangle_r.pipelineLayout, nil)
	vk.DestroyPipeline(vkDevice, Triangle_r.pipeline, nil)
}
vk_render :: proc() {
	vRes: vk.Result
	vkImgIdx: u32 = max(u32)


	vk.AcquireNextImageKHR(vkDevice, vkSwapchain, 0, vkSemaphores.acquire, 0, &vkImgIdx)
	assert(vkImgIdx != max(u32))


	cmd := vk.CommandBuffer{}
	vRes = vk.AllocateCommandBuffers(
		vkDevice,
		&vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandBufferCount = 1,
			commandPool        = vkCommandPool,
			// level = .PRIMARY,
		},
		&cmd,
	)
	vk_ensure(vRes)
	ensure(cmd != {})
	defer vk.FreeCommandBuffers(vkDevice, vkCommandPool, 1, &cmd)


	vRes = vk.BeginCommandBuffer(
		cmd,
		&vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
	)
	vk_ensure(vRes)

	clearColor := vk.ClearValue {
		color = {float32 = {.2, .4, .6, 1}},
	}

	vk.CmdBeginRenderPass(
		cmd,
		&vk.RenderPassBeginInfo {
			sType = .RENDER_PASS_BEGIN_INFO,
			renderPass = vkRenderPass,
			framebuffer = vkFrameBuffers[vkImgIdx],
			renderArea = vk.Rect2D {
				offset = {0, 0},
				extent = {width = u32(screenWidth), height = u32(screenHeight)},
			},
			clearValueCount = 1,
			pClearValues = &clearColor,
		},
		.INLINE,
	)
	{
		vk.CmdSetScissor(cmd, 0, 1, &vk.Rect2D{extent = {u32(screenWidth), u32(screenHeight)}})
		vk.CmdSetViewport(
			cmd,
			0,
			1,
			&vk.Viewport{maxDepth = 1.0, width = f32(screenWidth), height = f32(screenHeight)},
		)
		assert(Triangle_r.pipeline != {})
		vk.CmdBindPipeline(cmd, .GRAPHICS, Triangle_r.pipeline)
		vk.CmdDraw(cmd, 3, 1, 0, 0)
	}
	vk.CmdEndRenderPass(cmd)

	vRes = vk.EndCommandBuffer(cmd)
	vk_ensure(vRes)
	waitFlags := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	vRes = vk.QueueSubmit(
		vkQueue,
		1,
		&vk.SubmitInfo {
			sType = .SUBMIT_INFO,
			pWaitDstStageMask = &waitFlags,
			commandBufferCount = 1,
			pCommandBuffers = &cmd,
			pSignalSemaphores = &vkSemaphores.submit,
			signalSemaphoreCount = 1,
			pWaitSemaphores = &vkSemaphores.acquire,
			waitSemaphoreCount = 1,
		},
		0,
	)
	vk_ensure(vRes)

	vk.QueuePresentKHR(
		vkQueue,
		&vk.PresentInfoKHR {
			sType = .PRESENT_INFO_KHR,
			pSwapchains = &vkSwapchain,
			swapchainCount = 1,
			pImageIndices = &vkImgIdx,
			pWaitSemaphores = &vkSemaphores.submit,
			waitSemaphoreCount = 1,
		},
	)
	vk_ensure(vRes)

	vRes = vk.DeviceWaitIdle(vkDevice)
	vk_ensure(vRes)

}
